///|
// Host mocks share JS globals; serialize their tests so each observes its host.
let websocket_host_mock : @semaphore.Semaphore = @semaphore.Semaphore(1)

///|
async test "Node fetch refuses a validated WebSocket upgrade with 501 without starting the handler" {
  websocket_host_mock.acquire()
  defer websocket_host_mock.release()
  let called = Ref(false)
  let adapter = fetch_handler(request => {
    @facade_ws.upgrade(request, subprotocols=["echo"], handler=_ => {
      called.val = true
    })
  })
  let probe = Probe::new()
  let response = awaited(
    adapter(
      make_request("GET", b"", [
        ["host", "example.test"],
        ["connection", "Upgrade"],
        ["upgrade", "websocket"],
        ["sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="],
        ["sec-websocket-version", "13"],
        ["sec-websocket-protocol", "echo"],
      ]),
      probe.callback(),
    ),
  ).wait()
  assert_eq(response.status(), 501)
  assert_false(called.val)
  probe.settled().wait()
  assert_false(probe.failed())
}

///|
extern "js" fn bun_server_forwarded(
  adapter : (JsRequest, JsBackground) -> JsPromise,
) -> @js_async.Promise[Bool] =
  #| async adapter => {
  #|   const {resolve} = await import('node:path');
  #|   const {pathToFileURL} = await import('node:url');
  #|   const {existsSync} = await import('node:fs');
  #|   const root = existsSync(resolve('hosts/adapters.mjs')) ? resolve('hosts') : resolve('mttp/hosts');
  #|   const {bun} = await import(pathToFileURL(resolve(root, 'adapters.mjs')).href);
  #|   const app = bun(adapter);
  #|   let called = false, options;
  #|   const server = {upgrade(request, value) { options = value; called = typeof options.data.start === 'function'; return true; }};
  #|   const response = await app.fetch(new Request('https://example.test/ws', {headers: {
  #|     host: 'example.test', connection: 'Upgrade', upgrade: 'websocket', 'sec-websocket-version': '13',
  #|     'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ=='
  #|   }}), server);
  #|   app.websocket.open({data: options.data, readyState: 1, bufferedAmount: 0, send() {}, close() {}, terminate() {}});
  #|   await app.whenIdle();
  #|   return called && response === undefined && typeof app.websocket.open === 'function';
  #| }

///|
async test "Bun shim passes the second server argument and unwraps successful upgrades" {
  websocket_host_mock.acquire()
  defer websocket_host_mock.release()
  let adapter = fetch_handler(request => {
    @facade_ws.upgrade(request, handler=_ => ())
  })
  assert_true(bun_server_forwarded(adapter).wait())
}

///|
extern "js" fn shutdown_blocked_upgrade(
  adapter : (JsRequest, JsBackground) -> JsPromise,
  release : () -> Unit,
) -> @js_async.Promise[String] =
  #| async (adapter, release) => {
  #|   const {resolve} = await import('node:path');
  #|   const {pathToFileURL} = await import('node:url');
  #|   const {existsSync} = await import('node:fs');
  #|   const root = existsSync(resolve('hosts/adapters.mjs')) ? resolve('hosts') : resolve('mttp/hosts');
  #|   const shims = await import(pathToFileURL(resolve(root, 'adapters.mjs')).href);
  #|   const saved = Object.getOwnPropertyDescriptor(globalThis, 'Deno');
  #|   const results = [];
  #|   try {
  #|     for (const host of ['deno', 'bun']) for (const answers of [true, false]) {
  #|       let options, app;
  #|       const errors = [];
  #|       const socket = Object.assign(new EventTarget(), {readyState: 1, bufferedAmount: 0, protocol: '', send() {},
  #|         close(code, reason) { if (!answers) return; this.readyState = 3;
  #|           const event = new Event('close'); Object.assign(event, {code, reason}); this.dispatchEvent(event); }});
  #|       Object.defineProperty(globalThis, 'Deno', {configurable: true, value: host === 'deno' ? {
  #|         upgradeWebSocket() { return {socket, response: {status: 101, headers: new Headers()}}; }
  #|       } : undefined});
  #|       app = shims[host](adapter, error => errors.push(String(error)));
  #|       const request = new Request('https://example.test/ws', {headers: {host: 'example.test', connection: 'Upgrade',
  #|         upgrade: 'websocket', 'sec-websocket-version': '13', 'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ=='}});
  #|       await app.fetch(request, {upgrade(_, value) { options = value; return true; }});
  #|       if (host === 'bun') {
  #|         app.websocket.open({data: options.data, readyState: 1, bufferedAmount: 0, send() {}, terminate() {},
  #|           close(code, reason) { if (answers) app.websocket.close(this, code, reason); }});
  #|       }
  #|       await new Promise(resolve => setTimeout(resolve, 10));
  #|       app.shutdown();
  #|       let timer;
  #|       const idle = app.whenIdle().then(() => 'joined');
  #|       const result = await Promise.race([idle, new Promise(resolve => { timer = setTimeout(() => resolve('timeout'), 250); })]);
  #|       clearTimeout(timer);
  #|       results.push(`${host}/${answers}: ${result}${errors.length ? ' error' : ''}`);
  #|       // Release a broken implementation as well, so the red test leaves no tasks.
  #|       release(); await idle;
  #|     }
  #|   } finally {
  #|     if (saved) Object.defineProperty(globalThis, 'Deno', saved); else delete globalThis.Deno;
  #|   }
  #|   return results.join('|');
  #| }

///|
async test "shutdown cancels and joins handlers blocked outside recv after bounded close" {
  websocket_host_mock.acquire()
  defer websocket_host_mock.release()
  let blocked = @cond_var.Cond()
  let finished = Ref(0)
  let resumed = Ref(0)
  let adapter = fetch_handler(request => {
    @facade_ws.upgrade(
      request,
      limits={ ..@ws.WsLimits::default(), close_timeout_ms: 10, },
      handler=_ => {
        defer @async.protect_from_cancel(() => {
          @async.sleep(5)
          finished.val += 1
        })
        blocked.wait()
        resumed.val += 1
      },
    )
  })
  let result = shutdown_blocked_upgrade(adapter, () => {
    blocked.broadcast()
    defer_turn(turn)
  }).wait()
  assert_eq(
    result, "deno/true: joined|deno/false: joined|bun/true: joined|bun/false: joined",
  )
  assert_eq(finished.val, 4)
  assert_eq(resumed.val, 0)
}

///|
extern "js" fn shutdown_connecting_upgrade(
  adapter : (JsRequest, JsBackground) -> JsPromise,
  release : () -> Unit,
) -> @js_async.Promise[String] =
  #| async (adapter, release) => {
  #|   const {resolve} = await import('node:path');
  #|   const {pathToFileURL} = await import('node:url');
  #|   const {existsSync} = await import('node:fs');
  #|   const root = existsSync(resolve('hosts/adapters.mjs')) ? resolve('hosts') : resolve('mttp/hosts');
  #|   const {tracked, bun} = await import(pathToFileURL(resolve(root, 'adapters.mjs')).href);
  #|   const saved = new Map(['Deno', 'WebSocketPair', 'Response'].map(name => [name, Object.getOwnPropertyDescriptor(globalThis, name)]));
  #|   const OriginalResponse = globalThis.Response;
  #|   const results = [];
  #|   try {
  #|     for (const host of ['deno', 'bun-pending', 'bun-connecting', 'workers']) {
  #|       let closes = 0, options;
  #|       const errors = [];
  #|       const socket = Object.assign(new EventTarget(), {readyState: 0, bufferedAmount: 0, protocol: '', send() {},
  #|         // Deliberately never opens and never acknowledges Close.
  #|         close() { closes++; }, accept() {}});
  #|       Object.defineProperty(globalThis, 'Deno', {configurable: true, value: host === 'deno' ? {
  #|         upgradeWebSocket() { return {socket, response: {status: 101, headers: new Headers()}}; }
  #|       } : undefined});
  #|       Object.defineProperty(globalThis, 'WebSocketPair', {configurable: true, value: host === 'workers' ?
  #|         function() { return {0: {}, 1: socket}; } : undefined});
  #|       // Workers' real accept() is synchronous. A delayed fake exercises
  #|       // startup shutdown on the same host bridge without needing a browser.
  #|       function Response(body, init) {
  #|         return init?.status === 101 ? {status: 101, headers: new Headers(init.headers)} : new OriginalResponse(body, init);
  #|       }
  #|       Object.setPrototypeOf(Response, OriginalResponse); Response.prototype = OriginalResponse.prototype;
  #|       Object.defineProperty(globalThis, 'Response', {configurable: true, value: Response});
  #|       const app = host.startsWith('bun') ? bun(adapter, error => errors.push(String(error))) : tracked(adapter, error => errors.push(String(error)));
  #|       const request = new Request('https://example.test/ws', {headers: {host: 'example.test', connection: 'Upgrade',
  #|         upgrade: 'websocket', 'sec-websocket-version': '13', 'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ=='}});
  #|       await app.fetch(request, {upgrade(_, value) { options = value; return true; }});
  #|       const bunSocket = {data: options?.data, readyState: 0, bufferedAmount: 0, send() {},
  #|         close() { closes++; }, terminate() { closes++; }};
  #|       if (host === 'bun-connecting') app.websocket.open(bunSocket);
  #|       await new Promise(resolve => setTimeout(resolve, 5));
  #|       app.shutdown();
  #|       let timer;
  #|       const idle = app.whenIdle().then(() => 'joined');
  #|       const result = await Promise.race([idle, new Promise(resolve => { timer = setTimeout(() => resolve('timeout'), 150); })]);
  #|       clearTimeout(timer);
  #|       // A socket arriving after abandonment must be closed without starting
  #|       // its handler or reviving the already settled background promise.
  #|       if (host === 'bun-pending') app.websocket.open(bunSocket);
  #|       await new Promise(resolve => setTimeout(resolve, 5));
  #|       results.push(`${host}: ${result}${closes ? ' closed' : ' unclosed'}${errors.length ? ' error' : ''}`);
  #|       // Make the red implementation finish too, leaving no test tasks.
  #|       socket.readyState = 1; socket.dispatchEvent(new Event('open'));
  #|       bunSocket.readyState = 1;
  #|       if (host.startsWith('bun')) bunSocket.data.events.dispatchEvent(new Event('open'));
  #|       release(); await new Promise(resolve => setTimeout(resolve, 10)); release(); await idle;
  #|     }
  #|   } finally {
  #|     for (const [name, descriptor] of saved) {
  #|       if (descriptor) Object.defineProperty(globalThis, name, descriptor); else delete globalThis[name];
  #|     }
  #|   }
  #|   return results.join('|');
  #| }

///|
async test "shutdown during startup abandons connecting sockets within the close bound on every host" {
  websocket_host_mock.acquire()
  defer websocket_host_mock.release()
  let blocked = @cond_var.Cond()
  let called = Ref(0)
  let adapter = fetch_handler(request => {
    @facade_ws.upgrade(
      request,
      limits={
        ..@ws.WsLimits::default(),
        send_timeout_ms: 3000,
        close_timeout_ms: 15,
      },
      handler=_ => {
        called.val += 1
        blocked.wait()
      },
    )
  })
  let result = shutdown_connecting_upgrade(adapter, () => {
    blocked.broadcast()
    defer_turn(turn)
  }).wait()
  assert_eq(
    result, "deno: joined closed|bun-pending: joined closed|bun-connecting: joined closed|workers: joined closed",
  )
  assert_eq(called.val, 0)
}

///|
extern "js" fn deno_upgrade_headers(
  adapter : (JsRequest, JsBackground) -> JsPromise,
) -> @js_async.Promise[FixedArray[String]] =
  #| async adapter => {
  #|   const saved = Object.getOwnPropertyDescriptor(globalThis, 'Deno');
  #|   const socket = Object.assign(new EventTarget(), {readyState: 1, bufferedAmount: 0, protocol: 'echo', send() {}, close() {this.readyState = 3;}});
  #|   Object.defineProperty(globalThis, 'Deno', {configurable: true, value: {upgradeWebSocket() { return {socket,
  #|     response: {status: 101, headers: new Headers({connection: 'Upgrade', upgrade: 'websocket',
  #|       'sec-websocket-accept': 'host-accept', 'sec-websocket-protocol': 'echo', 'x-host': 'kept'})}}; }}});
  #|   try {
  #|     let background;
  #|     const response = await adapter(new Request('https://example.test/ws', {headers: {host: 'example.test', connection: 'Upgrade',
  #|       upgrade: 'websocket', 'sec-websocket-version': '13', 'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==', 'sec-websocket-protocol': 'echo'}}), promise => {background = promise;});
  #|     await background;
  #|     return [...response.headers.getSetCookie(), ...['x-app', 'x-host', 'connection', 'upgrade', 'sec-websocket-accept', 'sec-websocket-protocol'].map(name => response.headers.get(name) || '')];
  #|   } finally { if (saved) Object.defineProperty(globalThis, 'Deno', saved); else delete globalThis.Deno; }
  #| }

///|
async test "Deno upgrades preserve application cookies and host handshake headers" {
  websocket_host_mock.acquire()
  defer websocket_host_mock.release()
  let adapter = fetch_handler(request => {
    let response = @facade_ws.upgrade(request, subprotocols=["echo"], handler=_ => {
      ()
    })
    {
      ..response,
      headers: response.headers
      .add("set-cookie", "a=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT")
      .add("set-cookie", "b=2; HttpOnly")
      .add("x-app", "kept")
      .set("sec-websocket-accept", "application-cannot-replace-host"),
    }
  })
  assert_eq(deno_upgrade_headers(adapter).wait().iter().collect(), [
    "a=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT", "b=2; HttpOnly", "kept", "kept",
    "Upgrade", "websocket", "host-accept", "echo",
  ])
}

///|
extern "js" fn bun_client_headers(
  run : () -> @js_async.Promise[Unit],
) -> @js_async.Promise[String] =
  #| async run => {
  #|   const savedBun = Object.getOwnPropertyDescriptor(globalThis, 'Bun');
  #|   const savedSocket = globalThis.WebSocket;
  #|   let fields;
  #|   Object.defineProperty(globalThis, 'Bun', {configurable: true, value: {}});
  #|   globalThis.WebSocket = class extends EventTarget {
  #|     constructor(url, protocols, options = protocols) { super(); fields = new Headers(options.headers); this.readyState = 1; this.bufferedAmount = 0;
  #|       this.protocol = ''; queueMicrotask(() => this.dispatchEvent(new Event('open'))); }
  #|     close() { this.readyState = 3; const event = new Event('close'); Object.assign(event, {code: 1000, reason: ''}); this.dispatchEvent(event); }
  #|   };
  #|   try { await run(); return fields.get('accept') || ''; }
  #|   finally { globalThis.WebSocket = savedSocket; if (savedBun) Object.defineProperty(globalThis, 'Bun', savedBun); else delete globalThis.Bun; }
  #| }

///|
async test "Bun client preserves every repeated list header value in order" {
  websocket_host_mock.acquire()
  defer websocket_host_mock.release()
  let result = bun_client_headers(() => {
    @js_async.Promise::from_async(() => {
      let session = websocket_connect(
        "ws://example.test/",
        [],
        @mttp_core.Headers::of([
          ("Accept", "text/plain"),
          ("accept", "application/json"),
        ]),
        @ws.WsLimits::default(),
      )
      session.abort()
    })
  }).wait()
  assert_eq(result, "text/plain, application/json")
}

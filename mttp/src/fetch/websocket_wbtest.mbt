///|
async test "Node fetch refuses a validated WebSocket upgrade with 501 without starting the handler" {
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
  let adapter = fetch_handler(request => {
    @facade_ws.upgrade(request, handler=_ => ())
  })
  assert_true(bun_server_forwarded(adapter).wait())
}

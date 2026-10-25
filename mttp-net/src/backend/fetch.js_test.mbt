///|
#external
priv type MockFetch

///|
extern "js" fn MockFetch::new(mode : String, payload : Bytes) -> MockFetch =
  #| (mode, payload) => {
  #|   const original = globalThis.fetch;
  #|   const state = {mode, calls: 0, aborted: 0, cancelled: 0, init: null, url: '', restore: () => globalThis.fetch = original};
  #|   state.started = new Promise(resolve => state.markStarted = resolve);
  #|   globalThis.fetch = async (url, init) => {
  #|     const mode = state.mode;
  #|     state.calls++; state.init = init; state.url = url;
  #|     state.markStarted();
  #|     init.signal.addEventListener('abort', () => state.aborted++, {once: true});
  #|     if (mode === 'fail') throw new TypeError('test network failure');
  #|     if (mode === 'pending') return new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(new DOMException('cancelled', 'AbortError')), {once: true}));
  #|     if (mode === 'opaque') return {status: 0, headers: new Headers(), body: null};
  #|     if (mode === 'head') return new Response(null, {status: 204});
  #|     if (mode === 'redirect') return new Response(null, {status: 302, headers: {location: '/next'}});
  #|     const stream = new ReadableStream({
  #|       start(controller) {
  #|         if (mode === 'read-pending') return;
  #|         if (mode === 'empty') { for (let i = 0; i < 1024; i++) controller.enqueue(new Uint8Array(0)); }
  #|         controller.enqueue(payload); controller.close();
  #|       }, cancel() { state.cancelled++; }
  #|     });
  #|     return new Response(stream, {headers: {'content-type': 'text/plain', 'set-cookie': 'a=1'}});
  #|   };
  #|   return state;
  #| }

///|
extern "js" fn MockFetch::restore_ffi(self : MockFetch) -> Unit =
  #| state => state.restore()

///|
let mock_gate : @runtime.SemaphoreGate = @runtime.SemaphoreGate::new()

///|
async fn MockFetch::install(mode : String, payload : Bytes) -> MockFetch {
  mock_gate.acquire()
  MockFetch::new(mode, payload)
}

///|
fn MockFetch::restore(self : MockFetch) -> Unit {
  self.restore_ffi()
  mock_gate.release()
}

///|
extern "js" fn MockFetch::stats(self : MockFetch) -> FixedArray[Int32] =
  #| state => [state.calls, state.aborted, state.cancelled, state.init?.body?.length ?? 0]

///|
extern "js" fn MockFetch::option(self : MockFetch, name : String) -> String =
  #| (state, name) => name === 'url' ? state.url : String(state.init?.[name] ?? '')

///|
extern "js" fn MockFetch::header(self : MockFetch, name : String) -> String =
  #| (state, name) => state.init?.headers.get(name) ?? ''

///|
extern "js" fn MockFetch::mode(self : MockFetch, mode : String) -> Unit =
  #| (state, mode) => state.mode = mode

///|
extern "js" fn MockFetch::started(self : MockFetch) -> @js_async.Promise[Unit] =
  #| state => state.started

///|
async fn js_body(response : @model.Response) -> Bytes {
  defer response.close()
  match response.body {
    Empty => b""
    Bytes(bytes) => bytes
    Stream(cell) => @model.read_bounded(cell.take(), 20 * 1024 * 1024)
    @model.Body::.. => fail("unsupported body kind")
  }
}

///|
async test "JS backend validates shared contracts and keeps redirects manual" {
  let mock = MockFetch::install("redirect", b"")
  defer mock.restore()
  assert_eq(
    @testing.check_backend_contract(() => @backend.AsyncBackend::new()),
    [],
  )
  let backend = @backend.AsyncBackend::new()
  defer backend.close()
  let response = backend.send(
    @model.Request::get("http://example.test/p?q=1#fragment").header(
      "proxy-authorization", "secret",
    ),
    @client.RequestOptions::default(),
  )
  assert_eq(response.status, 302)
  assert_eq(response.headers.get("location"), Some("/next"))
  assert_eq(mock.option("redirect"), "manual")
  assert_eq(mock.option("url"), "http://example.test:80/p?q=1")
  assert_eq(mock.header("proxy-authorization"), "")
  assert_eq(js_body(response), b"")
  assert_eq(backend.idle_connections(), 0)
}

///|
async test "JS body slices are bounded and decoded byte limits close responses" {
  for limit in [69999, 70000] {
    let mock = MockFetch::install("normal", Bytes::make(70000, b'x'))
    defer mock.restore()
    let backend = @backend.AsyncBackend::new(max_body_bytes=limit)
    defer backend.close()
    let response = backend.send(
      @model.Request::get("http://example.test/"),
      @client.RequestOptions::default(),
    )
    if limit == 69999 {
      try js_body(response) catch {
        @model.TransportError(kind=TooLarge(limit=69999), phase=Body, ..) => ()
        error => raise error
      } noraise {
        _ => fail("body limit ignored")
      }
    } else {
      guard response.body is Stream(cell) else { fail("expected stream") }
      let stream = cell.take()
      assert_eq(stream.read_some().unwrap().length(), 65536)
      assert_eq(stream.read_some().unwrap().length(), 4464)
      assert_eq(stream.read_some(), None)
      assert_eq(stream.read_some(), None)
      response.close()
    }
    assert_eq(mock.stats()[1], 1)
  }
}

///|
async test "JS reports fetch failures in Unknown and rejects opaque responses" {
  for mode in ["fail", "opaque", "empty"] {
    let mock = MockFetch::install(mode, b"x")
    defer mock.restore()
    let backend = @backend.AsyncBackend::new()
    defer backend.close()
    try
      js_body(
        backend.send(
          @model.Request::get("http://example.test/"),
          @client.RequestOptions::default(),
        ),
      )
    catch {
      @model.TransportError(kind~, phase~, ..) => {
        assert_eq(kind, if mode == "fail" { Network } else { Protocol })
        assert_eq(phase, if mode == "empty" { Body } else { Unknown })
      }
      error => raise error
    } noraise {
      _ => fail("expected fetch failure")
    }
    assert_eq(mock.stats()[1], 1)
  }
}

///|
async test "JS explicit proxies forbidden methods and GET bodies fail before fetch" {
  let mock = MockFetch::install("normal", b"")
  defer mock.restore()
  let proxy = @backend.AsyncBackend::new(proxy="http://proxy.test")
  try
    proxy.send(
      @model.Request::get("http://example.test/"),
      @client.RequestOptions::default(),
    )
  catch {
    @model.TransportError(kind=Protocol, phase=Pool, ..) => ()
    error => raise error
  } noraise {
    _ => fail("proxy ignored")
  }
  let backend = @backend.AsyncBackend::new()
  defer backend.close()
  for
    request in [
      @model.Request::new(Connect, "http://example.test/"),
      @model.Request::get("http://example.test/").body_text("x"),
      @model.Request::get("http://example.test/").header("x-value", "字"),
    ] {
    try backend.send(request, @client.RequestOptions::default()) catch {
      @model.TransportError(kind=Invalid, ..) => ()
      error => raise error
    } noraise {
      _ => fail("invalid request sent")
    }
  }
  assert_eq(mock.stats()[0], 0)
}

///|
priv struct Zeros {
  total : Int32
  mut produced : Int32
  mut closed : Bool
}

///|
impl @model.BodyStream for Zeros with fn read_some(self) {
  let n = (self.total - self.produced).min(1024 * 1024)
  if n == 0 {
    return None
  }
  self.produced += n
  Some(Bytes::make(n, 0))
}

///|
impl @model.BodyStream for Zeros with fn close(self) {
  self.closed = true
}

///|
async test "JS upload buffering accepts exactly 16 MiB and refuses overflow" {
  let limit = 16 * 1024 * 1024
  for
    (total, declared) in [(limit + 1, true), (limit + 1, false), (limit, false)] {
    let mock = MockFetch::install("head", b"")
    defer mock.restore()
    let backend = @backend.AsyncBackend::new()
    defer backend.close()
    let source = Zeros::{ total, produced: 0, closed: false, }
    let length = if declared { Some(total.to_int64()) } else { None }
    let request = @model.Request::post("http://example.test/").body_stream(
      source,
      length?,
    )
    if total > limit {
      try backend.send(request, @client.RequestOptions::default()) catch {
        @model.TransportError(kind=TooLarge(limit=actual), phase=Write, ..) =>
          assert_eq(actual, limit)
        error => raise error
      } noraise {
        _ => fail("upload limit ignored")
      }
      assert_eq(mock.stats()[0], 0)
    } else {
      assert_eq(
        js_body(backend.send(request, @client.RequestOptions::default())),
        b"",
      )
      assert_eq(mock.stats()[3], limit)
    }
    assert_eq(source.produced, if declared { 0 } else { total })
    assert_eq(source.closed, !declared)
  }
}

///|
priv struct TestClock {
  started : @aqueue.Queue[Int32]
  wake : @cond_var.Cond
  mut pending : Int32
}

///|
fn TestClock::new() -> TestClock {
  {
    started: @aqueue.Queue(kind=Unbounded),
    wake: @cond_var.Cond(),
    pending: 0,
  }
}

///|
impl @clock.Clock for TestClock with fn now_unix_ms(_) {
  0L
}

///|
impl @clock.Clock for TestClock with fn sleep(self, ms) {
  self.pending += 1
  defer {
    self.pending -= 1
  }
  self.started.put(ms) catch {
    _ => ()
  }
  self.wake.wait()
}

///|
async test "JS fetch timeout and parent cancellation abort and free admission" {
  for timeout in [false, true] {
    let mock = MockFetch::install("pending", b"ok")
    defer mock.restore()
    let clock = TestClock::new()
    let backend = @backend.AsyncBackend::new(
      clock~,
      timeout_ms=700,
      max_connections=1,
    )
    defer backend.close()
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        try
          backend.send(
            @model.Request::get("http://example.test/"),
            @client.RequestOptions::default(),
          )
        catch {
          @model.TransportError(kind=Timeout(ms=700), phase=Unknown, ..) =>
            assert_true(timeout)
          error => raise error
        } noraise {
          _ => fail("pending fetch completed")
        }
      })
      mock.started().wait()
      assert_eq(clock.started.get(), 700)
      if timeout {
        clock.wake.signal()
      } else {
        group.return_immediately(())
      }
    })
    assert_eq(mock.stats()[1], 1)
    assert_eq(clock.pending, 0)
    mock.mode("normal")
    assert_eq(
      js_body(
        backend.send(
          @model.Request::get("http://example.test/"),
          @client.RequestOptions::default(),
        ),
      ),
      b"ok",
    )
  }
}

///|
async test "JS body timeout cancellation and early close cancel readers once" {
  for action in 0..<3 {
    let mock = MockFetch::install("read-pending", b"")
    defer mock.restore()
    let clock = TestClock::new()
    let backend = @backend.AsyncBackend::new(
      clock~,
      timeout_ms=700,
      max_connections=1,
    )
    defer backend.close()
    let response = backend.send(
      @model.Request::get("http://example.test/"),
      @client.RequestOptions::default(),
    )
    while clock.started.try_get() is Some(_) {
      ()
    }
    if action == 0 {
      response.close()
    } else {
      guard response.body is Stream(cell) else { fail("expected stream") }
      let reader = cell.take()
      @async.with_task_group(group => {
        group.spawn_bg(() => {
          try reader.read_some() catch {
            @model.TransportError(kind=Timeout(ms=700), phase=Body, ..) =>
              assert_eq(action, 1)
            error => raise error
          } noraise {
            _ => fail("pending body completed")
          }
        })
        assert_eq(clock.started.get(), 700)
        if action == 1 {
          clock.wake.signal()
        } else {
          group.return_immediately(())
        }
      })
      response.close()
    }
    response.close()
    assert_eq(mock.stats()[1], 1)
    assert_eq(mock.stats()[2], 1)
    assert_eq(clock.pending, 0)
    mock.mode("head")
    backend
    .send(
      @model.Request::get("http://example.test/"),
      @client.RequestOptions::default(),
    )
    .close()
  }
}

///|
#external
priv type NodeServer

///|
extern "js" fn NodeServer::start() -> @js_async.Promise[NodeServer] =
  #| async () => {
  #|   const http = await import('node:http');
  #|   const zlib = await import('node:zlib');
  #|   const state = {requests: 0};
  #|   const server = http.createServer((req, res) => {
  #|     state.requests++;
  #|     if (req.url === '/redirect') { res.writeHead(302, {location: '/gzip'}); res.end(); return; }
  #|     if (req.url === '/slow') { res.writeHead(200); res.flushHeaders(); return; }
  #|     if (req.url === '/echo') {
  #|       const chunks = [];
  #|       req.on('data', chunk => chunks.push(chunk));
  #|       req.on('end', () => res.end(Buffer.concat(chunks)));
  #|       return;
  #|     }
  #|     const bytes = zlib.gzipSync('decoded');
  #|     res.writeHead(200, {'content-encoding': 'gzip', 'content-length': bytes.length, 'set-cookie': ['a=1', 'b=2']});
  #|     res.end(bytes);
  #|   });
  #|   await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  #|   state.url = `http://127.0.0.1:${server.address().port}`;
  #|   state.close = () => { server.closeAllConnections(); server.close(); };
  #|   return state;
  #| }

///|
extern "js" fn NodeServer::url(self : NodeServer) -> String =
  #| state => state.url

///|
extern "js" fn NodeServer::requests(self : NodeServer) -> Int32 =
  #| state => state.requests

///|
extern "js" fn NodeServer::close(self : NodeServer) -> Unit =
  #| state => state.close()

///|
async test "Node fetch integration preserves single sends uploads decoded bodies and read timeout" {
  mock_gate.acquire()
  defer mock_gate.release()
  @async.with_timeout(5000, () => {
    let server = NodeServer::start().wait()
    defer server.close()
    let backend = @backend.AsyncBackend::new(max_connections=1)
    defer backend.close()
    let response = backend.send(
      @model.Request::get(server.url() + "/redirect"),
      @client.RequestOptions::default(),
    )
    assert_eq(response.status, 302)
    assert_eq(server.requests(), 1)
    assert_eq(js_body(response), b"")
    let response = backend.send(@model.Request::get(server.url() + "/gzip"), {
      ..@client.RequestOptions::default(),
      decompress: false,
    })
    assert_eq(response.headers.get_all("set-cookie"), ["a=1", "b=2"])
    assert_eq(js_body(response), b"decoded")
    let payload = Bytes::make(70000, b'x')
    assert_eq(
      js_body(
        backend.send(
          @model.Request::post(server.url() + "/echo").body_bytes(payload),
          @client.RequestOptions::default(),
        ),
      ),
      payload,
    )
    let response = backend.send(@model.Request::get(server.url() + "/slow"), {
      ..@client.RequestOptions::default(),
      read_idle_ms: Some(30),
    })
    try js_body(response) catch {
      @model.TransportError(kind=Timeout(ms=30), phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("stalled fetch body completed")
    }
    assert_eq(
      js_body(
        backend.send(
          @model.Request::get(server.url() + "/gzip"),
          @client.RequestOptions::default(),
        ),
      ),
      b"decoded",
    )
  })
}

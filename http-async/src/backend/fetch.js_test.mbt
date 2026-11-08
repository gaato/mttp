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
  #|         if (mode === 'empty' || mode === 'empty-ok') { for (let i = 0; i < (mode === 'empty' ? 1024 : 1023); i++) controller.enqueue(new Uint8Array(0)); }
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
async fn js_body(response : @http.Response) -> Bytes {
  defer response.close()
  match response.body {
    Empty => b""
    Bytes(bytes) => bytes
    Stream(cell) => @http.read_bounded(cell.take(), 20 * 1024 * 1024)
    @http.Body::.. => fail("unsupported test body")
  }
}

///|
async test "JS fetch keeps redirects manual strips proxy credentials and normalizes URL" {
  let mock = MockFetch::install("redirect", b"")
  defer mock.restore()
  let backend = @backend.AsyncBackend::new()
  defer backend.close()
  let response = backend.send(
    @http.Request::get("http://example.test/p?q=1#fragment").header(
      "proxy-authorization", "secret",
    ),
    @http.SendOptions::default(),
  )
  assert_eq(response.status, 302)
  assert_eq(response.headers.get("location"), Some("/next"))
  assert_eq(mock.option("redirect"), "manual")
  assert_eq(mock.option("url"), "http://example.test:80/p?q=1")
  assert_eq(mock.header("proxy-authorization"), "")
  assert_eq(js_body(response), b"")
  assert_eq(backend.idle_connections(), 0)
  assert_eq(mock.stats()[0], 1)
}

///|
async test "JS fetch omits implicit browser credentials" {
  let mock = MockFetch::install("head", b"")
  defer mock.restore()
  let backend = @backend.AsyncBackend::new()
  defer backend.close()
  backend
  .send(
    @http.Request::get("https://example.test/").header(
      "authorization", "Bearer explicit",
    ),
    @http.SendOptions::default(),
  )
  .close()
  assert_eq(mock.option("credentials"), "omit")
  assert_eq(mock.header("authorization"), "Bearer explicit")
}

///|
async test "JS delivery slices are at most 64 KiB and EOF and close are sticky" {
  let mock = MockFetch::install("normal", Bytes::make(70000, b'x'))
  defer mock.restore()
  let backend = @backend.AsyncBackend::new()
  defer backend.close()
  let response = backend.send(
    @http.Request::get("http://example.test/"),
    @http.SendOptions::default(),
  )
  guard response.body is Stream(cell) else { fail("expected stream") }
  let stream = cell.take()
  assert_eq(stream.read_some().unwrap().length(), 65536)
  assert_eq(stream.read_some().unwrap().length(), 4464)
  assert_eq(stream.read_some(), None)
  assert_eq(stream.read_some(), None)
  response.close()
  response.close()
  assert_eq(stream.read_some(), None)
  assert_eq(mock.stats()[1], 1)
}

///|
async test "JS Exchange caps and engine ceilings refuse the crossing host chunk" {
  for
    (cap, ceiling, streaming) in [
      (69999, None, false),
      (80000, Some(69999), false),
      (80000, Some(69999), true),
    ] {
    let mock = MockFetch::install("normal", Bytes::make(70000, b'x'))
    defer mock.restore()
    let backend = @backend.AsyncBackend::new(config={
      ..@h1client.ClientConfig::default(),
      max_body_bytes: ceiling,
    })
    defer backend.close()
    let response = backend.send(@http.Request::get("http://example.test/"), {
      timeout_ms: None,
      body: if streaming {
        Stream(idle_ms=None)
      } else {
        Exchange(max_bytes=cap)
      },
    })
    guard response.body is Stream(cell) else { fail("expected stream") }
    let stream = cell.take()
    try stream.read_some() catch {
      @http.TransportError(kind=TooLarge(limit=69999), phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("crossing host chunk was exposed")
    }
    assert_eq(stream.read_some(), None)
    assert_eq(mock.stats()[1], 1)
  }
}

///|
async test "JS Stream has no per request length cap and ignores socket configuration and trust" {
  let mock = MockFetch::install("normal", Bytes::make(70000, b'x'))
  defer mock.restore()
  let backend = @backend.AsyncBackend::new(
    config={
      ..@h1client.ClientConfig::default(),
      proxy: @h1client.ProxyConfig::fixed("invalid proxy"),
      connect_timeout_ms: Some(0),
      read_timeout_ms: Some(0),
      write_timeout_ms: Some(0),
      pool_timeout_ms: Some(0),
      max_connections: Some(0),
      max_idle_connections: 0,
    },
    trust=PemFile("nonexistent.pem"),
  )
  defer backend.close()
  assert_eq(
    js_body(
      backend.send(@http.Request::get("http://example.test/"), {
        timeout_ms: None,
        body: Stream(idle_ms=None),
      }),
    ).length(),
    70000,
  )
}

///|
async test "JS network opaque and 1024 empty host chunk failures abort" {
  for mode in ["fail", "opaque", "empty"] {
    let mock = MockFetch::install(mode, b"x")
    defer mock.restore()
    let backend = @backend.AsyncBackend::new()
    defer backend.close()
    try
      js_body(
        backend.send(
          @http.Request::get("http://example.test/"),
          @http.SendOptions::default(),
        ),
      )
    catch {
      @http.TransportError(kind~, phase~, ..) => {
        assert_eq(kind, if mode == "fail" { Network } else { Protocol })
        assert_eq(phase, if mode == "empty" { Body } else { Unknown })
      }
      error => raise error
    } noraise {
      _ => fail("expected fetch failure")
    }
    assert_eq(mock.stats()[1], 1)
  }
  let mock = MockFetch::install("empty-ok", b"x")
  defer mock.restore()
  let backend = @backend.AsyncBackend::new()
  defer backend.close()
  assert_eq(
    js_body(
      backend.send(
        @http.Request::get("http://example.test/"),
        @http.SendOptions::default(),
      ),
    ),
    b"x",
  )
}

///|
async test "JS length validation accepts padded lengths and checks buffered unknown streams" {
  let mock = MockFetch::install("head", b"")
  defer mock.restore()
  let backend = @backend.AsyncBackend::new()
  defer backend.close()
  backend
  .send(
    @http.Request::post("http://example.test/")
    .body_text("abc")
    .header("content-length", "003"),
    @http.SendOptions::default(),
  )
  .close()
  let source = Zeros::{ total: 3, produced: 0, closes: 0, }
  try
    backend.send(
      @http.Request::post("http://example.test/")
      .body_stream(source)
      .header("content-length", "4"),
      @http.SendOptions::default(),
    )
  catch {
    @http.TransportError(kind=Invalid, phase=Pool, ..) => ()
    error => raise error
  } noraise {
    _ => fail("buffered length mismatch accepted")
  }
  assert_eq(source.closes, 1)
  assert_eq(mock.stats()[0], 1)
}

///|
async test "JS invalid URLs methods framing and GET bodies fail before fetch" {
  let mock = MockFetch::install("normal", b"")
  defer mock.restore()
  let backend = @backend.AsyncBackend::new()
  defer backend.close()
  for
    request in [
      @http.Request::get("/relative"),
      @http.Request::get("ftp://example.test/"),
      @http.Request::get("http://user:pass@example.test/"),
      @http.Request::new(Connect, "http://example.test/"),
      @http.Request::new(Other("TRACE"), "http://example.test/"),
      @http.Request::get("http://example.test/").body_text("x"),
      @http.Request::get("http://example.test/").header("x-value", "字"),
      @http.Request::post("http://example.test/")
      .body_text("abc")
      .header("content-length", "2"),
      @http.Request::post("http://example.test/")
      .header("content-length", "0")
      .header("transfer-encoding", "chunked"),
    ] {
    try backend.send(request, @http.SendOptions::default()) catch {
      @http.TransportError(kind=Invalid, phase=Pool, ..) => ()
      error => raise error
    } noraise {
      _ => fail("invalid request sent")
    }
  }
  let invalid = @backend.AsyncBackend::new(config={
    ..@h1client.ClientConfig::default(),
    max_body_bytes: Some(-1),
  })
  defer invalid.close()
  try
    invalid.send(
      @http.Request::get("http://example.test/"),
      @http.SendOptions::default(),
    )
  catch {
    @http.TransportError(kind=Invalid, phase=Pool, ..) => ()
    error => raise error
  } noraise {
    _ => fail("negative ceiling accepted")
  }
  assert_eq(mock.stats()[0], 0)
}

///|
priv struct Zeros {
  total : Int32
  mut produced : Int32
  mut closes : Int32
}

///|
impl @http.BodyStream for Zeros with fn read_some(self) {
  let n = (self.total - self.produced).min(1024 * 1024)
  if n == 0 {
    return None
  }
  self.produced += n
  Some(Bytes::make(n, 0))
}

///|
impl @http.BodyStream for Zeros with fn close(self) {
  self.closes += 1
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
    let source = Zeros::{ total, produced: 0, closes: 0, }
    let request = @http.Request::post("http://example.test/").body_stream(
      source,
      length?=if declared { Some(total.to_int64()) } else { None },
    )
    if total > limit {
      try backend.send(request, @http.SendOptions::default()) catch {
        @http.TransportError(kind=TooLarge(limit=actual), phase=Write, ..) =>
          assert_eq(actual, limit)
        error => raise error
      } noraise {
        _ => fail("upload cap ignored")
      }
      assert_eq(mock.stats()[0], 0)
    } else {
      assert_eq(
        js_body(backend.send(request, @http.SendOptions::default())),
        b"",
      )
      assert_eq(mock.stats()[3], limit)
    }
    assert_eq(source.produced, if declared { 0 } else { total })
    assert_eq(source.closes, 1)
  }
  let mock = MockFetch::install("head", b"")
  defer mock.restore()
  let backend = @backend.AsyncBackend::new()
  defer backend.close()
  try
    backend.send(
      @http.Request::post("http://example.test/").body_bytes(
        Bytes::make(limit + 1, 0),
      ),
      @http.SendOptions::default(),
    )
  catch {
    @http.TransportError(kind=TooLarge(limit=actual), phase=Write, ..) =>
      assert_eq(actual, limit)
    error => raise error
  } noraise {
    _ => fail("byte upload cap ignored")
  }
  assert_eq(mock.stats()[0], 0)
}

///|
async test "JS attempt timeout and parent cancellation abort pending fetch unchanged" {
  for timeout in [true, false] {
    let mock = MockFetch::install("pending", b"")
    defer mock.restore()
    let backend = @backend.AsyncBackend::new()
    defer backend.close()
    let caught = Ref(false)
    let cleaned = Ref(false)
    @async.with_task_group(group => {
      let task = group.spawn(() => {
        defer {
          cleaned.val = true
        }
        try
          backend.send(@http.Request::get("http://example.test/"), {
            ..@http.SendOptions::default(),
            timeout_ms: if timeout {
              Some(30)
            } else {
              None
            },
          })
        catch {
          @http.TransportError(kind=Timeout(ms=30), phase=Unknown, ..) =>
            caught.val = true
          error => raise error
        } noraise {
          _ => fail("pending fetch completed")
        }
      })
      mock.started().wait()
      if !timeout {
        group.return_immediately()
      } else {
        task.wait()
      }
    })
    assert_true(cleaned.val)
    assert_eq(caught.val, timeout)
    assert_eq(mock.stats()[1], 1)
    mock.mode("head")
    backend
    .send(
      @http.Request::get("http://example.test/"),
      @http.SendOptions::default(),
    )
    .close()
  }
}

///|
async test "JS Exchange body and Stream idle deadlines cancel readers" {
  for streaming in [true, false] {
    let mock = MockFetch::install("read-pending", b"")
    defer mock.restore()
    let backend = @backend.AsyncBackend::new()
    defer backend.close()
    let response = backend.send(@http.Request::get("http://example.test/"), {
      timeout_ms: if streaming {
        Some(1000)
      } else {
        Some(30)
      },
      body: if streaming {
        Stream(idle_ms=Some(30))
      } else {
        Exchange(max_bytes=100)
      },
    })
    try js_body(response) catch {
      @http.TransportError(kind=Timeout(ms=30), phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("stalled body completed")
    }
    assert_eq(mock.stats()[1], 1)
    assert_eq(mock.stats()[2], 1)
  }
}

///|
async test "JS early close and cancelled reads close once without swallowing cancellation" {
  for cancel in [true, false] {
    let mock = MockFetch::install("read-pending", b"")
    defer mock.restore()
    let backend = @backend.AsyncBackend::new()
    defer backend.close()
    let response = backend.send(
      @http.Request::get("http://example.test/"),
      @http.SendOptions::default(),
    )
    if cancel {
      let caught = Ref(false)
      @async.with_task_group(group => {
        group.spawn_bg(() => {
          ignore(
            js_body(response) catch {
              _ => {
                caught.val = true
                b""
              }
            },
          )
        })
        @async.pause()
        group.return_immediately()
      })
      assert_false(caught.val)
    } else {
      response.close()
    }
    response.close()
    assert_eq(mock.stats()[1], 1)
    assert_eq(mock.stats()[2], 1)
  }
}

///|
async test "JS Stream ends the attempt deadline at the head" {
  let mock = MockFetch::install("normal", b"ok")
  defer mock.restore()
  let backend = @backend.AsyncBackend::new()
  defer backend.close()
  let response = backend.send(@http.Request::get("http://example.test/"), {
    timeout_ms: Some(100),
    body: Stream(idle_ms=None),
  })
  @async.sleep(120)
  assert_eq(js_body(response), b"ok")
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
async test "Node fetch integration decodes gzip echoes uploads and preserves redirects and cookies" {
  mock_gate.acquire()
  defer mock_gate.release()
  @async.with_timeout(5000, () => {
    let server = @js_async.run_promise(_ => NodeServer::start())
    defer server.close()
    let backend = @backend.AsyncBackend::new()
    defer backend.close()
    let response = backend.send(
      @http.Request::get(server.url() + "/redirect"),
      @http.SendOptions::default(),
    )
    assert_eq(response.status, 302)
    assert_eq(server.requests(), 1)
    assert_eq(js_body(response), b"")
    let response = backend.send(
      @http.Request::get(server.url() + "/gzip"),
      @http.SendOptions::default(),
    )
    assert_eq(response.headers.get_all("set-cookie"), ["a=1", "b=2"])
    assert_eq(js_body(response), b"decoded")
    let payload = Bytes::make(70000, b'x')
    assert_eq(
      js_body(
        backend.send(
          @http.Request::post(server.url() + "/echo").body_bytes(payload),
          @http.SendOptions::default(),
        ),
      ),
      payload,
    )
    let response = backend.send(@http.Request::get(server.url() + "/slow"), {
      timeout_ms: None,
      body: Stream(idle_ms=Some(30)),
    })
    try js_body(response) catch {
      @http.TransportError(kind=Timeout(ms=30), phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("stalled Node response succeeded")
    }
    assert_eq(
      js_body(
        backend.send(
          @http.Request::get(server.url() + "/gzip"),
          @http.SendOptions::default(),
        ),
      ),
      b"decoded",
    )
  })
}

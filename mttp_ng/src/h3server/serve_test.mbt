// The HTTP/3 server against this module's HTTP/3 client and curl, on
// 127.0.0.1, with the test certificate of mttp_ng/testdata.

///|
async fn testdata(name : String) -> String {
  for dir in ["../../testdata", "testdata", "mttp_ng/testdata"] {
    if @fs.exists("\{dir}/\{name}") {
      return @fs.realpath("\{dir}/\{name}")
    }
  }
  fail("no testdata/\{name} below the working directory")
}

///|
async fn answer(request : @mttp_core.Request) -> @mttp_core.Response noraise {
  let url = @mttp_core.Url::parse(request.url) catch {
    _ => return @mttp_core.Response::new(400)
  }
  match url.path {
    "/hello" =>
      @mttp_core.Response::new(
        200,
        headers=@mttp_core.Headers::of([
          (
            "x-protocol",
            request.attributes.get(@mttp_core.protocol).unwrap_or(""),
          ),
        ]),
        body=Bytes(b"hello"),
      )
    "/echo" => {
      let body = request.body.read_all(max=8 << 20) catch {
        _ => return @mttp_core.Response::new(400)
      }
      @mttp_core.Response::new(
        200,
        headers=@mttp_core.Headers::of([
          ("x-received", body.length().to_string()),
        ]),
        body=Bytes(body),
      )
    }
    "/big" =>
      @mttp_core.Response::new(
        200,
        body=Bytes(Bytes::makei(2000000, i => (i % 251).to_byte())),
      )
    "/stream" =>
      @mttp_core.Response::new(
        200,
        body=Stream(@mttp_core.StreamBody::new({ left: 50, size: 20000, })),
      )
    "/early" => @mttp_core.Response::new(413, body=Bytes(b"early"))
    "/ignore" => {
      // Lets the request body arrive, and answers without reading it.
      @async.sleep(100)
      @mttp_core.Response::new(200, body=Bytes(b"ignored"))
    }
    "/stuck" =>
      // A response whose body stops yielding after its first piece (the
      // first is pulled before the head).
      @mttp_core.Response::new(
        200,
        body=Stream(@mttp_core.StreamBody::new(Stuck::{ started: false, })),
      )
    "/silent" =>
      // A response whose body never yields its first piece.
      @mttp_core.Response::new(
        200,
        body=Stream(@mttp_core.StreamBody::new(Stuck::{ started: true, })),
      )
    "/slow" => {
      @async.sleep(300)
      @mttp_core.Response::new(200, body=Bytes(b"slow"))
    }
    _ => @mttp_core.Response::new(404)
  }
}

///|
/// `left` pieces of `size` bytes.
priv struct Pieces {
  mut left : Int32
  size : Int32
}

///|
impl @mttp_core.BodyStream for Pieces with fn read_some(self) {
  if self.left == 0 {
    return None
  }
  self.left -= 1
  Some(Bytes::make(self.size, b'p'))
}

///|
impl @mttp_core.BodyStream for Pieces with fn close(_) {
  ()
}

///|
/// A body source that yields one piece, then never again.
priv struct Stuck {
  mut started : Bool
}

///|
impl @mttp_core.BodyStream for Stuck with fn read_some(self) {
  if !self.started {
    self.started = true
    return Some(b"x")
  }
  @async.sleep(1000000)
  None
}

///|
impl @mttp_core.BodyStream for Stuck with fn close(_) {
  ()
}

///|
async fn with_server(
  run : async (Int32) -> Unit,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
) -> Unit {
  let quic = @h3.ServerQuic::from_pem(
    chain=@fs.read_text(testdata("localhost.pem")),
    key=@fs.read_text(testdata("localhost.key")),
  )
  @async.with_timeout(30000, () => {
    @async.with_task_group(group => {
      let port : Ref[Int32?] = Ref(None)
      let listening = @cond_var.Cond()
      group.spawn_bg(() => {
        @h3server.serve(answer, addr="127.0.0.1:0", quic~, limits~, on_listen=addr => {
          port.val = Some(
            @string.parse_int(addr[addr.rev_find(":").unwrap() + 1:]) catch {
              _ => 0
            },
          )
          listening.broadcast()
        })
      })
      while port.val is None {
        listening.wait()
      }
      run(port.val.unwrap())
      group.return_immediately()
    })
  })
}

///|
async fn client() -> @h3client.H3Backend {
  @h3client.H3Backend::new(trust=PemFile(testdata("root.pem")))
}

///|
let defaults : @mttp_core.SendOptions = @mttp_core.SendOptions::default()

///|
async fn text(response : @mttp_core.Response) -> String {
  @utf8.decode_lossy(response.body.read_all(max=16 << 20))
}

///|
async test "HTTP/3 between this module's client and server" {
  with_server(port => {
    let b = client()
    defer b.close()
    let response = b.send(
      @mttp_core.Request::get("https://localhost:\{port}/hello"),
      defaults,
    )
    assert_eq(response.status, 200)
    assert_eq(response.attributes.get(@mttp_core.protocol), Some("h3"))
    assert_eq(response.headers.get("x-protocol"), Some("h3"))
    assert_eq(text(response), "hello")
    // The same connection carries the next ones, some at once.
    let answers = []
    @async.with_task_group(group => {
      for _ in 0..<10 {
        group.spawn_bg(() => {
          let response = b.send(
            @mttp_core.Request::get("https://localhost:\{port}/hello"),
            defaults,
          )
          answers.push(text(response))
        })
      }
    })
    assert_eq(answers, Array::make(10, "hello"))
    assert_eq(b.connections(), 1)
  })
}

///|
async test "bodies both ways over HTTP/3" {
  with_server(port => {
    let b = client()
    defer b.close()
    let big = Bytes::makei(500000, i => (i % 241).to_byte())
    let response = b.send(
      @mttp_core.Request::put("https://localhost:\{port}/echo").body_bytes(big),
      defaults,
    )
    assert_eq(response.headers.get("x-received"), Some("500000"))
    assert_true(response.body.read_all(max=1 << 20) == big)
    let response = b.send(
      @mttp_core.Request::get("https://localhost:\{port}/big"),
      defaults,
    )
    assert_eq(response.body.read_all(max=4 << 20).length(), 2000000)
  })
}

///|
async test "try_send declines an origin without HTTP/3, sending nothing" {
  let b = client()
  defer b.close()
  // Nothing listens on UDP port 1.
  let outcome = b.try_send(
    @mttp_core.Request::get("https://127.0.0.1:1/"),
    defaults,
  )
  assert_true(outcome is None)
  // And the origin is not tried again for a while.
  let outcome = b.try_send(
    @mttp_core.Request::get("https://127.0.0.1:1/"),
    defaults,
  )
  assert_true(outcome is None)
}

///|
async test "curl speaks HTTP/3 to it" {
  with_server(port => {
    let result = @process.run(
      "curl",
      [
        "--silent",
        "--show-error",
        "--http3-only",
        "--cacert",
        testdata("root.pem"),
        "--write-out",
        " %{http_version}",
        "https://localhost:\{port}/hello",
      ],
      stdout=Collect,
      stderr=Collect,
    )
    assert_eq(
      result.exit_code,
      0,
      msg=@utf8.decode_lossy(result.stderr_binary()),
    )
    assert_eq(@utf8.decode_lossy(result.stdout_binary()), "hello 3")
  })
}

///|
async test "streamed response bodies, early answers and the limits over HTTP/3" {
  with_server(
    limits={
      ..@h1server.ServerLimits::default(),
      max_body_bytes: 100000,
      handler_timeout_ms: Some(100),
    },
    port => {
      let b = client()
      defer b.close()
      let response = b.send(
        @mttp_core.Request::get("https://localhost:\{port}/stream"),
        defaults,
      )
      assert_eq(response.body.read_all(max=4 << 20).length(), 1000000)
      // Declared too large: 413 before the handler.
      let response = b.send(
        @mttp_core.Request::post("https://localhost:\{port}/echo").body_bytes(
          Bytes::make(200000, b'x'),
        ),
        defaults,
      )
      assert_eq(response.status, 413)
      ignore(text(response))
      // Streamed too large: the read that crosses it fails, and 413.
      let response = b.send(
        {
          ..@mttp_core.Request::post("https://localhost:\{port}/echo"),
          body: Stream(@mttp_core.StreamBody::new({ left: 20, size: 10000, })),
        },
        defaults,
      )
      assert_eq(response.status, 413)
      ignore(text(response))
      // An answer before the request body: the client stops sending.
      let response = b.send(
        {
          ..@mttp_core.Request::post("https://localhost:\{port}/early"),
          body: Stream(
            @mttp_core.StreamBody::new({ left: 100000, size: 16384, }),
          ),
        },
        defaults,
      )
      assert_eq(response.status, 413)
      assert_eq(text(response), "early")
      // A handler over its deadline: 504.
      let response = b.send(
        @mttp_core.Request::get("https://localhost:\{port}/slow"),
        defaults,
      )
      assert_eq(response.status, 504)
      ignore(text(response))
    },
  )
}

///|
/// QUIC counts the request streams of a connection's life: the server gives
/// one back for each that closes, so a connection carries more requests
/// than `max_streams_bidi` (Codex's review of #58).
async test "one connection carries more requests than the stream limit" {
  with_server(port => {
    let b = client()
    defer b.close()
    for _ in 0..<150 {
      let response = b.send(
        @mttp_core.Request::get("https://localhost:\{port}/hello"),
        defaults,
      )
      assert_eq(text(response), "hello")
    }
    assert_eq(b.connections(), 1)
  })
}

///|
/// A response body whose source stops yielding is cut off after
/// `body_timeout_ms`, as HTTP/1.1 and HTTP/2 do (Codex's review of #58).
async test "a stuck response body is reset after body_timeout_ms" {
  with_server(
    limits={ ..@h1server.ServerLimits::default(), body_timeout_ms: 200, },
    port => {
      let b = client()
      defer b.close()
      let response = b.send(
        @mttp_core.Request::get("https://localhost:\{port}/stuck"),
        defaults,
      )
      try response.body.read_all(max=1024) catch {
        @mttp_core.TransportError(phase~, ..) => assert_eq(phase, Body)
      } noraise {
        _ => fail("a stuck body ended")
      }
    },
  )
}

///|
/// A request body that sends a small piece every 40 ms, for 40 seconds.
priv struct Trickle {
  mut left : Int32
}

///|
impl @mttp_core.BodyStream for Trickle with fn read_some(self) {
  if self.left == 0 {
    return None
  }
  self.left -= 1
  @async.sleep(40)
  Some(Bytes::make(100, b't'))
}

///|
impl @mttp_core.BodyStream for Trickle with fn close(_) {
  ()
}

///|
async test "a request body that keeps trickling ends at body_timeout_ms" {
  // Each piece wakes the handler's read; the body's deadline runs from its
  // first read all the same. Were it reset by each piece, the upload would
  // outlast the test's 30 seconds.
  with_server(
    limits={ ..@h1server.ServerLimits::default(), body_timeout_ms: 300, },
    port => {
      let client = client()
      defer client.close()
      let response = client.send(
        {
          ..@mttp_core.Request::post("https://localhost:\{port}/echo"),
          body: Stream(@mttp_core.StreamBody::new({ left: 1000, })),
        },
        defaults,
      )
      // The body's failure decides the answer, as h1server's does.
      assert_eq(response.status, 408)
      response.close()
    },
  )
}

///|
/// Body bytes a handler never read give the connection's window back when
/// its stream ends, or a few such requests would hold the window shut for
/// every later one (the audit of #58).
async test "request bodies nobody read leave the connection's window open" {
  with_server(port => {
    let b = client()
    defer b.close()
    // More than the connection's window (1 MiB) in all.
    for _ in 0..<8 {
      let response = b.send(
        @mttp_core.Request::post("https://localhost:\{port}/ignore").body_bytes(
          Bytes::make(200000, b'x'),
        ),
        defaults,
      )
      assert_eq(text(response), "ignored")
    }
    let response = b.send(
      @mttp_core.Request::post("https://localhost:\{port}/echo").body_bytes(
        Bytes::make(200000, b'y'),
      ),
      defaults,
    )
    assert_eq(response.headers.get("x-received"), Some("200000"))
    ignore(text(response))
    assert_eq(b.connections(), 1)
  })
}

///|
/// The first piece of a streamed response is pulled before the head: a
/// producer silent for `body_timeout_ms` from the start is answered 500.
async test "a response body silent from its start is answered 500" {
  with_server(
    limits={ ..@h1server.ServerLimits::default(), body_timeout_ms: 200, },
    port => {
      let b = client()
      defer b.close()
      let response = b.send(
        @mttp_core.Request::get("https://localhost:\{port}/silent"),
        defaults,
      )
      assert_eq(response.status, 500)
      ignore(text(response))
    },
  )
}

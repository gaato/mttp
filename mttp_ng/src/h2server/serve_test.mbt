// The server against this module's HTTP/2 client, gaato/mttp's HTTP/1.1
// client and curl, all on 127.0.0.1, with the test certificate of
// mttp_ng/testdata.

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
async fn server_tls() -> @tls.ServerTls {
  @tls.ServerTls::from_pem(
    chain=@fs.read_text(testdata("localhost.pem")),
    key=@fs.read_text(testdata("localhost.key")),
  )
}

///|
/// How many `/drained` handlers started.
let drained_started : Ref[Int32] = Ref(0)

///|
/// The test handler, by path.
async fn answer(request : @mttp_core.Request) -> @mttp_core.Response noraise {
  let url = @mttp_core.Url::parse(request.url) catch {
    _ => return @mttp_core.Response::new(400)
  }
  match url.path {
    "/hello" =>
      @mttp_core.Response::new(
        200,
        headers=@mttp_core.Headers::of([
          ("content-type", "text/plain"),
          (
            "x-protocol",
            request.attributes.get(@mttp_core.protocol).unwrap_or(""),
          ),
          (
            "x-scheme",
            request.attributes.get(@mttp_core.connection_scheme).unwrap_or(""),
          ),
          // A connection-specific field the server must leave out.
          ("connection", "keep-alive"),
        ]),
        body=Bytes(b"hello"),
      )
    "/echo" => {
      let body = request.body.read_all(max=8 << 20) catch {
        error =>
          return @mttp_core.Response::new(
            if error is @mttp_core.TransportError(kind=TooLarge(..), ..) {
              413
            } else {
              400
            },
          )
      }
      @mttp_core.Response::new(
        200,
        headers=@mttp_core.Headers::of([
          ("x-received", body.length().to_string()),
          ("x-method", request.meth.to_string()),
        ]),
        body=Bytes(body),
      )
    }
    "/big" =>
      @mttp_core.Response::new(
        200,
        body=Stream(@mttp_core.StreamBody::new({ left: 100, size: 30000, })),
      )
    "/slow" => {
      @async.sleep(300)
      @mttp_core.Response::new(200, body=Bytes(b"slow"))
    }
    "/drained" => {
      drained_started.val += 1
      @async.sleep(300)
      @mttp_core.Response::new(200, body=Bytes(b"drained"))
    }
    "/early" =>
      // Answers without reading the request body.
      @mttp_core.Response::new(413, body=Bytes(b"early"))
    _ => @mttp_core.Response::new(404)
  }
}

///|
/// A response body of `left` pieces of `size` bytes.
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
/// Runs `run` with a server listening on 127.0.0.1, then stops it.
async fn with_server(
  run : async (Int32) -> Unit,
  tls~ : Bool = true,
  h2c~ : Bool = false,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
  h2_limits~ : @h2server.H2Limits = @h2server.H2Limits::default(),
) -> Unit {
  let config = if tls { Some(server_tls()) } else { None }
  @async.with_timeout(30000, () => {
    @async.with_task_group(group => {
      let port : Ref[Int32?] = Ref(None)
      let listening = @cond_var.Cond()
      group.spawn_bg(() => {
        @h2server.serve(
          answer,
          addr="127.0.0.1:0",
          tls?=config,
          h2c~,
          limits~,
          h2_limits~,
          on_listen=addr => {
            port.val = Some(
              @string.parse_int(addr[addr.rev_find(":").unwrap() + 1:]) catch {
                _ => 0
              },
            )
            listening.broadcast()
          },
        )
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
async fn h2_client(h2c~ : Bool = false) -> @h2client.H2Backend {
  @h2client.H2Backend::new(trust=PemFile(testdata("root.pem")), h2c~)
}

///|
let defaults : @mttp_core.SendOptions = @mttp_core.SendOptions::default()

///|
async fn text(response : @mttp_core.Response) -> String {
  @utf8.decode_lossy(response.body.read_all(max=16 << 20))
}

///|
async test "HTTP/2 over TLS, between this module's client and server" {
  with_server(port => {
    let client = h2_client()
    defer client.close()
    let response = client.send(
      @mttp_core.Request::get("https://localhost:\{port}/hello"),
      defaults,
    )
    assert_eq(response.status, 200)
    assert_eq(response.attributes.get(@mttp_core.protocol), Some("h2"))
    assert_eq(response.headers.get("x-protocol"), Some("h2"))
    assert_eq(response.headers.get("x-scheme"), Some("https"))
    assert_eq(response.headers.get("connection"), None)
    assert_true(response.headers.get("date") is Some(_))
    assert_eq(text(response), "hello")
  })
}

///|
async test "bodies both ways, and many streams at once" {
  with_server(port => {
    let client = h2_client()
    defer client.close()
    let big = Bytes::makei(300000, i => (i % 251).to_byte())
    let response = client.send(
      @mttp_core.Request::put("https://localhost:\{port}/echo").body_bytes(big),
      defaults,
    )
    assert_eq(response.headers.get("x-received"), Some("300000"))
    assert_true(response.body.read_all(max=1 << 20) == big)
    let response = client.send(
      @mttp_core.Request::get("https://localhost:\{port}/big"),
      defaults,
    )
    assert_eq(response.body.read_all(max=8 << 20).length(), 3000000)
    let answers = []
    @async.with_task_group(group => {
      for _ in 0..<40 {
        group.spawn_bg(() => {
          let response = client.send(
            @mttp_core.Request::get("https://localhost:\{port}/hello"),
            defaults,
          )
          answers.push(text(response))
        })
      }
    })
    assert_eq(answers.length(), 40)
    assert_true(answers.iter().all(a => a == "hello"))
    assert_eq(client.connections(), 1)
  })
}

///|
async test "a body over max_body_bytes is answered 413" {
  with_server(
    limits={ ..@h1server.ServerLimits::default(), max_body_bytes: 1000, },
    port => {
      let client = h2_client()
      defer client.close()
      // Declared: refused before the handler.
      let response = client.send(
        @mttp_core.Request::post("https://localhost:\{port}/echo").body_bytes(
          Bytes::make(5000, b'x'),
        ),
        defaults,
      )
      assert_eq(response.status, 413)
      ignore(text(response))
      // Streamed: the read that crosses it fails.
      let response = client.send(
        {
          ..@mttp_core.Request::post("https://localhost:\{port}/echo"),
          body: Stream(@mttp_core.StreamBody::new({ left: 5, size: 1000, })),
        },
        defaults,
      )
      assert_eq(response.status, 413)
      ignore(text(response))
    },
  )
}

///|
async test "an early answer ends the client's upload" {
  with_server(port => {
    let client = h2_client()
    defer client.close()
    let response = client.send(
      {
        ..@mttp_core.Request::post("https://localhost:\{port}/early"),
        body: Stream(
          @mttp_core.StreamBody::new({ left: 1000000, size: 16384, }),
        ),
      },
      defaults,
    )
    assert_eq(response.status, 413)
    assert_eq(text(response), "early")
    // The connection serves the next request.
    let response = client.send(
      @mttp_core.Request::get("https://localhost:\{port}/hello"),
      defaults,
    )
    assert_eq(text(response), "hello")
  })
}

///|
async test "a handler over handler_timeout_ms is answered 504" {
  with_server(
    limits={
      ..@h1server.ServerLimits::default(),
      handler_timeout_ms: Some(50),
    },
    port => {
      let client = h2_client()
      defer client.close()
      let response = client.send(
        @mttp_core.Request::get("https://localhost:\{port}/slow"),
        defaults,
      )
      assert_eq(response.status, 504)
      ignore(text(response))
    },
  )
}

///|
async test "a client without h2 by ALPN gets HTTP/1.1" {
  with_server(port => {
    // gaato/mttp's own backend speaks HTTP/1.1 and offers no ALPN.
    let client = @backend.AsyncBackend::new(
      config=@h1client.ClientConfig::default(),
      trust=PemFile(testdata("root.pem")),
    )
    defer client.close()
    let response = client.send(
      @mttp_core.Request::get("https://localhost:\{port}/hello"),
      defaults,
    )
    assert_eq(response.headers.get("x-protocol"), Some("http/1.1"))
    assert_eq(text(response), "hello")
  })
}

///|
async test "cleartext: HTTP/2 by prior knowledge with h2c, HTTP/1.1 otherwise" {
  with_server(tls=false, h2c=true, port => {
    let client = h2_client(h2c=true)
    defer client.close()
    let response = client.send(
      @mttp_core.Request::get("http://127.0.0.1:\{port}/hello"),
      defaults,
    )
    assert_eq(response.headers.get("x-protocol"), Some("h2"))
    assert_eq(response.headers.get("x-scheme"), Some("http"))
    assert_eq(text(response), "hello")
    let plain = @backend.AsyncBackend::new(
      config=@h1client.ClientConfig::default(),
    )
    defer plain.close()
    let response = plain.send(
      @mttp_core.Request::post("http://127.0.0.1:\{port}/echo").body_bytes(
        b"over HTTP/1.1",
      ),
      defaults,
    )
    assert_eq(text(response), "over HTTP/1.1")
  })
}

///|
async test "curl speaks HTTP/2 to it" {
  with_server(port => {
    let result = @process.run(
      "curl",
      [
        "--silent",
        "--show-error",
        "--http2",
        "--cacert",
        testdata("root.pem"),
        "--write-out",
        " %{http_version}",
        "https://localhost:\{port}/hello",
      ],
      stdout=Collect,
    )
    assert_eq(result.exit_code, 0)
    assert_eq(@utf8.decode_lossy(result.stdout_binary()), "hello 2")
  })
}

///|
async test "a stop lets a stream in flight finish" {
  let config = server_tls()
  let client = h2_client()
  defer client.close()
  let outcome : Ref[String?] = Ref(None)
  @async.with_timeout(30000, () => {
    @async.with_task_group(outer => {
      let port : Ref[Int32?] = Ref(None)
      let listening = @cond_var.Cond()
      let server = outer.spawn(allow_failure=true, () => {
        @h2server.serve(answer, addr="127.0.0.1:0", tls=config, on_listen=addr => {
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
      let port = port.val.unwrap()
      outer.spawn_bg(() => {
        let response = client.send(
          @mttp_core.Request::get("https://localhost:\{port}/drained"),
          defaults,
        )
        outcome.val = Some(text(response))
      })
      // Stopped once the request is in its handler.
      let started = drained_started.val
      while drained_started.val == started {
        @async.sleep(10)
      }
      server.cancel()
    })
  })
  assert_eq(outcome.val, Some("drained"))
}

///|
/// The handler cap refuses new streams but keeps reading the connection:
/// a handler reading a body that arrives in many DATA frames gets it whole.
/// (Pausing the reads at the cap starved such a handler, Codex's review of
/// #58.)
async test "at the handler cap, a running handler still gets its body" {
  with_server(
    h2_limits={ ..@h2server.H2Limits::default(), max_concurrent_streams: 1, },
    port => {
      let client = h2_client()
      defer client.close()
      let response = client.send(
        {
          ..@mttp_core.Request::post("https://localhost:\{port}/echo"),
          body: Stream(@mttp_core.StreamBody::new({ left: 40, size: 10000, })),
        },
        defaults,
      )
      assert_eq(response.headers.get("x-received"), Some("400000"))
      assert_eq(response.body.read_all(max=1 << 20).length(), 400000)
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
      let client = h2_client()
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

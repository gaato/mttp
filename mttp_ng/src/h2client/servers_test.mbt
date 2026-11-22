// H2Backend against the local node:http2 server of testdata/h2_server.mjs,
// which says what each path does. Everything binds 127.0.0.1.

///|
/// The listeners of one server process.
priv struct Server {
  h2c : String
  tls : String
}

///|
/// A file of mttp_ng/testdata, from wherever moon runs the tests.
async fn testdata(name : String) -> String {
  for dir in ["../../testdata", "testdata", "mttp_ng/testdata"] {
    if @fs.exists("\{dir}/\{name}") {
      return @fs.realpath("\{dir}/\{name}")
    }
  }
  fail("no testdata/\{name} below the working directory")
}

///|
/// Runs `run` against a fresh server, bounded so that a hang fails the test
/// instead of the suite.
async fn with_server(
  run : async (Server) -> Unit,
  max_streams? : Int32,
) -> Unit {
  let args = [testdata("h2_server.mjs")]
  if max_streams is Some(n) {
    args.push("--max-streams")
    args.push(n.to_string())
  }
  @async.with_timeout(30000, () => {
    @async.with_task_group(group => {
      let (stdin, feed) = @process.write_to_process()
      let (out, stdout) = @process.read_from_process()
      let child = @process.spawn(
        group,
        "node",
        args,
        stdin=Shared(stdin),
        stdout=Shared(stdout),
      )
      defer {
        feed.close()
        out.close()
        child.cancel()
      }
      guard out.read_until(b"\n") is Some(line) else {
        fail("the test server printed no ports")
      }
      let ports = @json.parse(@utf8.decode_lossy(line))
      guard ports is { "h2c": Number(h2c, ..), "tls": Number(tls, ..), .. } else {
        fail("unexpected ports line: \{ports.stringify()}")
      }
      run({
        h2c: "http://127.0.0.1:\{h2c.to_int()}",
        tls: "https://localhost:\{tls.to_int()}",
      })
      group.return_immediately()
    })
  })
}

///|
async fn backend(h2c~ : Bool = false) -> @h2client.H2Backend {
  @h2client.H2Backend::new(trust=PemFile(testdata("root.pem")), h2c~)
}

///|
async fn text(response : @mttp_core.Response) -> String {
  @utf8.decode_lossy(response.body.read_all(max=16 << 20))
}

///|
let defaults : @mttp_core.SendOptions = @mttp_core.SendOptions::default()

///|
/// The failure of `send`, or a test failure when it succeeds.
async fn failure(
  b : @h2client.H2Backend,
  request : @mttp_core.Request,
  options~ : @mttp_core.SendOptions = defaults,
) -> @mttp_core.TransportError {
  try b.send(request, options) catch {
    @mttp_core.TransportError(..) as error => error
  } noraise {
    response => {
      response.close()
      fail("\{request.url} answered \{response.status}")
    }
  }
}

///|
async test "a GET over TLS speaks h2 and says so" {
  with_server(server => {
    let b = backend()
    defer b.close()
    let response = b.send(
      @mttp_core.Request::get(server.tls + "/hello"),
      defaults,
    )
    assert_eq(response.status, 200)
    assert_eq(response.headers.get("content-type"), Some("text/plain"))
    assert_eq(response.attributes.get(@mttp_core.protocol), Some("h2"))
    assert_eq(text(response), "hello")
  })
}

///|
async test "concurrent requests share one connection" {
  with_server(server => {
    let b = backend()
    defer b.close()
    let answers = []
    @async.with_task_group(group => {
      for _ in 0..<8 {
        group.spawn_bg(() => {
          let response = b.send(
            @mttp_core.Request::get(server.tls + "/session"),
            defaults,
          )
          answers.push(text(response))
        })
      }
    })
    assert_eq(answers, Array::make(8, "1"))
    assert_eq(b.connections(), 1)
    // A later request reuses it.
    let response = b.send(
      @mttp_core.Request::get(server.tls + "/session"),
      defaults,
    )
    assert_eq(text(response), "1")
  })
}

///|
async test "a server limit of one stream still completes every request" {
  with_server(max_streams=1, server => {
    let b = backend()
    defer b.close()
    let answers = []
    @async.with_task_group(group => {
      for _ in 0..<4 {
        group.spawn_bg(() => {
          let response = b.send(
            @mttp_core.Request::get(server.tls + "/wait/50"),
            defaults,
          )
          answers.push(text(response))
        })
      }
    })
    assert_eq(answers, Array::make(4, "waited"))
    assert_eq(b.connections(), 1)
  })
}

///|
/// A request body that yields `pieces` pieces of `size` bytes.
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
  Some(Bytes::make(self.size, b'u'))
}

///|
impl @mttp_core.BodyStream for Pieces with fn close(_) {
  ()
}

///|
async test "bodies of known length and streamed ones arrive whole" {
  with_server(server => {
    let b = backend()
    defer b.close()
    let request = @mttp_core.Request::post(server.tls + "/echo").body_bytes(
      b"posted",
    )
    let response = b.send(request, defaults)
    assert_eq(response.headers.get("x-method"), Some("POST"))
    assert_eq(response.headers.get("x-received"), Some("6"))
    assert_eq(text(response), "posted")
    let streamed = {
      ..@mttp_core.Request::put(server.tls + "/echo"),
      body: Stream(@mttp_core.StreamBody::new({ left: 50, size: 10000, })),
    }
    let response = b.send(streamed, defaults)
    assert_eq(response.headers.get("x-received"), Some("500000"))
    assert_eq(response.body.read_all(max=1 << 20).length(), 500000)
  })
}

///|
async test "a large response streams through the windows" {
  with_server(server => {
    let b = backend()
    defer b.close()
    let response = b.send(
      @mttp_core.Request::get(server.tls + "/big/5000000"),
      { ..defaults, body: Exchange(max_bytes=8 << 20), },
    )
    assert_eq(response.body.read_all(max=8 << 20).length(), 5000000)
  })
}

///|
async test "refused streams are Refused, so unsent" {
  with_server(server => {
    let b = backend()
    defer b.close()
    let error = failure(b, @mttp_core.Request::get(server.tls + "/refuse"))
    guard error is @mttp_core.TransportError(kind=Refused, ..) else {
      fail("unexpected \{error}")
    }
    assert_true(error.is_unsent())
    let error = failure(b, @mttp_core.Request::post(server.tls + "/goaway"))
    guard error is @mttp_core.TransportError(kind=Refused, ..) else {
      fail("unexpected \{error}")
    }
    // The next request goes on a new connection.
    let response = b.send(
      @mttp_core.Request::get(server.tls + "/goaway"),
      defaults,
    )
    assert_eq(text(response), "after goaway")
  })
}

///|
async test "a stream reset during its body fails the read in phase Body" {
  with_server(server => {
    let b = backend()
    defer b.close()
    let response = b.send(
      @mttp_core.Request::get(server.tls + "/reset-body"),
      defaults,
    )
    try response.body.read_all(max=1024) catch {
      @mttp_core.TransportError(phase~, ..) => assert_eq(phase, Body)
    } noraise {
      _ => fail("a reset body read to its end")
    }
  })
}

///|
async test "bounds and deadlines fail in the phase they bound" {
  with_server(server => {
    let b = backend()
    defer b.close()
    let error = failure(
      b,
      @mttp_core.Request::get(server.tls + "/big-head/30000"),
    )
    guard error is @mttp_core.TransportError(kind=TooLarge(..), phase=Head, ..) else {
      fail("unexpected \{error}")
    }
    let error = failure(b, @mttp_core.Request::get(server.tls + "/hang"), options={
      ..defaults,
      timeout_ms: Some(300),
    })
    guard error is @mttp_core.TransportError(kind=Timeout(..), phase=Head, ..) else {
      fail("unexpected \{error}")
    }
    let response = b.send(@mttp_core.Request::get(server.tls + "/stall"), {
      ..defaults,
      body: Stream(idle_ms=Some(200)),
    })
    try response.body.read_all(max=1024) catch {
      @mttp_core.TransportError(kind~, phase~, ..) => {
        guard kind is Timeout(..) else { fail("unexpected \{kind.to_repr()}") }
        assert_eq(phase, Body)
      }
    } noraise {
      _ => fail("a stalled body ended")
    }
    let response = b.send(@mttp_core.Request::get(server.tls + "/big/100000"), {
      ..defaults,
      body: Exchange(max_bytes=1000),
    })
    try response.body.read_all(max=1 << 20) catch {
      @mttp_core.TransportError(kind~, phase~, ..) => {
        guard kind is TooLarge(..) else { fail("unexpected \{kind.to_repr()}") }
        assert_eq(phase, Body)
      }
    } noraise {
      _ => fail("a body over its bound was read")
    }
    // The connection survived each of these.
    let response = b.send(
      @mttp_core.Request::get(server.tls + "/session"),
      defaults,
    )
    assert_eq(text(response), "1")
  })
}

///|
async test "phase events come in order, without Dialed on a reused connection" {
  with_server(server => {
    let b = backend()
    defer b.close()
    let seen = []
    let request = @mttp_core.Request::get(server.tls + "/hello").attribute(
      @mttp_core.on_phase,
      event => seen.push(event),
    )
    ignore(text(b.send(request, defaults)))
    guard seen
      is [Dialed(..), TlsDone, Pooled(reused=false), Written, FirstByte] else {
      fail("unexpected events \{@debug.to_string(seen)}")
    }
    seen.clear()
    ignore(text(b.send(request, defaults)))
    assert_eq(seen, [Pooled(reused=true), Written, FirstByte])
  })
}

///|
async test "an early answer stops the upload and keeps its body" {
  with_server(server => {
    let b = backend()
    defer b.close()
    // A body that would take far longer than the test.
    let endless = {
      ..@mttp_core.Request::post(server.tls + "/early/413"),
      body: Stream(@mttp_core.StreamBody::new({ left: 1000000, size: 16384, })),
    }
    let response = b.send(endless, defaults)
    assert_eq(response.status, 413)
    assert_eq(text(response), "early")
  })
}

///|
async test "cleartext HTTP/2 only with h2c" {
  with_server(server => {
    let b = backend(h2c=true)
    defer b.close()
    let response = b.send(
      @mttp_core.Request::get(server.h2c + "/hello"),
      defaults,
    )
    assert_eq(text(response), "hello")
    let plain = backend()
    defer plain.close()
    let error = failure(plain, @mttp_core.Request::get(server.h2c + "/hello"))
    guard error is @mttp_core.TransportError(kind=Invalid, phase=Pool, ..) else {
      fail("unexpected \{error}")
    }
  })
}

///|
async test "a closed backend refuses sends in phase Pool" {
  let b = backend()
  b.close()
  b.close()
  let error = failure(b, @mttp_core.Request::get("https://localhost/"))
  guard error is @mttp_core.TransportError(kind=Closed, phase=Pool, ..) else {
    fail("unexpected \{error}")
  }
}

// The backend against local servers: the Backend contract, HTTP/1.1 against
// mttp_async's server, HTTP/2 over TLS against moonhttp's server state
// machine, and how each kind of failure is reported.

///|
/// Reads a response body whole, closing it.
async fn read_text(response : @mttp.Response) -> String {
  let bytes = match response.body {
    Stream(cell) => @mttp.read_bounded(cell.take(), 1 << 20)
    Bytes(bytes) => bytes
    _ => b""
  }
  @utf8.decode_lossy(bytes[:])
}

///|
/// A request body in pieces, counting the reads and whether it was closed.
priv struct Pieces {
  pieces : Array[Bytes]
  mut next : Int32
  mut closed : Bool
}

///|
impl @mttp.BodyStream for Pieces with fn read_some(self) {
  if self.closed || self.next >= self.pieces.length() {
    return None
  }
  self.next += 1
  Some(self.pieces[self.next - 1])
}

///|
impl @mttp.BodyStream for Pieces with fn close(self) {
  self.closed = true
}

///|
/// A request body whose first read fails.
priv struct Broken {
  mut closed : Bool
}

///|
impl @mttp.BodyStream for Broken with fn read_some(_) {
  raise @mttp.TransportError(kind=Network, phase=Write, detail="disk gone")
}

///|
impl @mttp.BodyStream for Broken with fn close(self) {
  self.closed = true
}

///|
/// The TransportError `f` raises; fails the test when it returns.
async fn transport_error(
  f : async () -> @mttp.Response,
) -> @mttp.TransportError {
  let response = f() catch {
    @mttp.TransportError(_) as error => return error
    other => fail("not a TransportError: \{other}")
  }
  response.close()
  fail("the send succeeded")
}

///|
async test "the backend keeps mttp's Backend contract" {
  let port = closed_port()
  @sim.check_backend_contract(
    () => @mttp_moonfetch.backend(),
    url="http://127.0.0.1:\{port}/",
  )
}

///|
async test "HTTP/1.1: a GET to mttp_async's server, with the version attribute" {
  with_h1_server(
    request => {
      @mttp.Response::new(
        200,
        body=Bytes(@utf8.encode("hello \{request.meth.to_string()}")),
      )
    },
    address => {
      let backend = @mttp_moonfetch.backend()
      defer backend.close()
      let response = backend.send(
        @mttp.Request::get("http://\{address}/"),
        @mttp.SendOptions::default(),
      )
      assert_eq(response.status, 200)
      assert_eq(
        response.attributes.get(@mttp_moonfetch.http_version),
        Some("HTTP/1.1"),
      )
      assert_eq(read_text(response), "hello GET")
    },
  )
}

///|
async test "HTTP/1.1: Host comes from the URL, and each exchange has its own connection" {
  let connections = Ref(0)
  let hosts : Array[String] = []
  with_tcp_server(
    conn => {
      connections.val += 1
      // Answers keep-alive requests until the client closes the connection.
      while conn.read_until("\r\n\r\n") is Some(head) {
        for line in head.split("\r\n") {
          if line.to_lower().has_prefix("host:") {
            hosts.push(line[5:].trim(chars=" ").to_owned())
          }
        }
        conn.write(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
      }
    },
    port => {
      let backend = @mttp_moonfetch.backend()
      defer backend.close()
      for _ in 0..<2 {
        let response = backend.send(
          @mttp.Request::get("http://127.0.0.1:\{port}/").header(
            "host", "elsewhere.example",
          ),
          @mttp.SendOptions::default(),
        )
        assert_eq(read_text(response), "ok")
      }
      assert_eq(hosts, ["127.0.0.1:\{port}", "127.0.0.1:\{port}"])
      assert_eq(connections.val, 2)
    },
  )
}

///|
async test "HTTP/1.1: a streamed request body arrives whole and is closed" {
  let seen : Ref[(String, String)] = Ref(("", ""))
  with_h1_server(
    request => {
      let body = match request.body {
        Stream(cell) =>
          @mttp.read_bounded(cell.take(), 1 << 20) catch {
            _ => b""
          }
        Bytes(bytes) => bytes
        _ => b""
      }
      seen.val = (
        request.headers.get("content-length").unwrap_or("none"),
        @utf8.decode_lossy(body[:]),
      )
      @mttp.Response::new(204)
    },
    address => {
      let backend = @mttp_moonfetch.backend()
      defer backend.close()
      let source = Pieces::{
        pieces: [b"one,", b"two,", b"three"],
        next: 0,
        closed: false,
      }
      let response = backend.send(
        @mttp.Request::post("http://\{address}/upload").body_stream(
          source,
          length=13,
        ),
        @mttp.SendOptions::default(),
      )
      response.close()
      assert_eq(response.status, 204)
      assert_eq(seen.val, ("13", "one,two,three"))
      assert_true(source.closed)
    },
  )
}

///|
async test "a request stream whose first read fails sends nothing" {
  let requests = Ref(0)
  with_h1_server(
    _ => {
      requests.val += 1
      @mttp.Response::new(200)
    },
    address => {
      let backend = @mttp_moonfetch.backend()
      defer backend.close()
      let source = Broken::{ closed: false, }
      let error = transport_error(() => {
        backend.send(
          @mttp.Request::post("http://\{address}/").body_stream(source),
          @mttp.SendOptions::default(),
        )
      })
      assert_eq(error.message(), "Network during Write: disk gone")
      assert_true(source.closed)
      assert_eq(requests.val, 0)
    },
  )
}

///|
async test "responses are decompressed: gzip, br and zstd" {
  let accepted = Ref("")
  let encoded = [
    (
      "gzip", b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\x4b\x49\x4d\xce\x4f\x49\x4d\x51\x48\xaa\x54\xc8\x2d\x29\x29\x00\x00\xe7\x13\x0d\xa1\x0f\x00\x00\x00",
    ),
    (
      "br", b"\x0f\x07\x80\x64\x65\x63\x6f\x64\x65\x64\x20\x62\x79\x20\x6d\x74\x74\x70\x03",
    ),
    (
      "zstd", b"\x28\xb5\x2f\xfd\x04\x58\x79\x00\x00\x64\x65\x63\x6f\x64\x65\x64\x20\x62\x79\x20\x6d\x74\x74\x70\x94\xe7\xcb\x6a",
    ),
  ]
  with_h1_server(
    request => {
      accepted.val = request.headers.get("accept-encoding").unwrap_or("")
      let coding = request.url
        .split("/")
        .last()
        .map(s => s.to_owned())
        .unwrap_or("")
      let body = encoded
        .iter()
        .find_first(e => e.0 == coding)
        .map(e => e.1)
        .unwrap_or(b"")
      @mttp.Response::new(
        200,
        headers=@mttp.Headers::of([("content-encoding", coding)]),
        body=Bytes(body),
      )
    },
    address => {
      let backend = @mttp_moonfetch.backend()
      defer backend.close()
      for item in encoded {
        let response = backend.send(
          @mttp.Request::get("http://\{address}/\{item.0}"),
          @mttp.SendOptions::default(),
        )
        assert_eq(response.headers.get("content-encoding"), None)
        assert_eq(read_text(response), "decoded by mttp", msg=item.0)
        assert_eq(accepted.val, "gzip, deflate, br, zstd")
      }
      // A caller that names its own Accept-Encoding gets the body as sent.
      let response = backend.send(
        @mttp.Request::get("http://\{address}/gzip").header(
          "accept-encoding", "gzip",
        ),
        @mttp.SendOptions::default(),
      )
      assert_eq(response.headers.get("content-encoding"), Some("gzip"))
      response.close()
    },
  )
}

///|
async test "a redirect comes back raw, and mttp's Client follows it" {
  with_h1_server(
    request => {
      if request.url.has_suffix("/old") {
        @mttp.Response::new(
          301,
          headers=@mttp.Headers::of([("location", "/new")]),
        )
      } else {
        @mttp.Response::new(200, body=Bytes(b"moved here"))
      }
    },
    address => {
      let backend = @mttp_moonfetch.backend()
      let raw = backend.send(
        @mttp.Request::get("http://\{address}/old"),
        @mttp.SendOptions::default(),
      )
      raw.close()
      assert_eq(raw.status, 301)
      assert_eq(raw.headers.get("location"), Some("/new"))
      let api = @mttp_async.client(base_url="http://\{address}", backend~)
      defer api.close()
      let reply = api.send(@mttp_async.get("/old"))
      assert_eq(reply.status, 200)
      assert_eq(reply.body, Ok("moved here"))
    },
  )
}

///|
async test "a refused connection is a Connect failure and unsent" {
  let port = closed_port()
  let backend = @mttp_moonfetch.backend()
  defer backend.close()
  let error = transport_error(() => {
    backend.send(
      @mttp.Request::post("http://127.0.0.1:\{port}/").body_bytes(b"x"),
      @mttp.SendOptions::default(),
    )
  })
  let @mttp.TransportError(kind~, phase~, ..) = error
  assert_eq(kind, Connect)
  assert_eq(phase, Dial)
  assert_true(error.is_unsent())
}

///|
async test "a server that closes before replying: the request may have been sent" {
  with_tcp_server(conn => read_head(conn), port => {
    let backend = @mttp_moonfetch.backend()
    defer backend.close()
    let error = transport_error(() => {
      backend.send(
        @mttp.Request::post("http://127.0.0.1:\{port}/").body_bytes(b"x"),
        @mttp.SendOptions::default(),
      )
    })
    let @mttp.TransportError(kind~, phase~, ..) = error
    assert_eq(kind, Network)
    assert_eq(phase, Unknown)
    assert_false(error.is_unsent())
  })
}

///|
async test "the attempt deadline covers the head" {
  with_tcp_server(
    conn => {
      read_head(conn)
      @async.sleep(5000)
    },
    port => {
      let backend = @mttp_moonfetch.backend()
      defer backend.close()
      let error = transport_error(() => {
        backend.send(@mttp.Request::get("http://127.0.0.1:\{port}/"), {
          ..@mttp.SendOptions::default(),
          timeout_ms: Some(200),
        })
      })
      let @mttp.TransportError(kind~, phase~, ..) = error
      assert_eq(kind, Timeout(ms=200))
      assert_eq(phase, Unknown)
      assert_false(error.is_unsent())
    },
  )
}

///|
/// A server that sends a head promising ten bytes, five of them, and stalls.
async fn stalls_in_the_body(conn : @tcp.Conn) -> Unit {
  read_head(conn)
  conn.write(b"HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\n01234")
  @async.sleep(5000)
}

///|
async test "with Exchange, the attempt deadline covers the body too" {
  with_tcp_server(stalls_in_the_body, port => {
    let backend = @mttp_moonfetch.backend()
    defer backend.close()
    let response = backend.send(
      @mttp.Request::get("http://127.0.0.1:\{port}/"),
      { ..@mttp.SendOptions::default(), timeout_ms: Some(300), },
    )
    let error = transport_error(() => {
      ignore(read_text(response))
      response
    })
    let @mttp.TransportError(kind~, phase~, ..) = error
    assert_eq(kind, Timeout(ms=300))
    assert_eq(phase, Body)
  })
}

///|
async test "with Stream, each body read waits at most the idle limit" {
  with_tcp_server(stalls_in_the_body, port => {
    let backend = @mttp_moonfetch.backend()
    defer backend.close()
    let response = backend.send(
      @mttp.Request::get("http://127.0.0.1:\{port}/"),
      { timeout_ms: Some(1000), body: Stream(idle_ms=Some(150)), },
    )
    guard response.body is Stream(cell) else { fail("not a stream") }
    let stream = cell.take()
    defer stream.close()
    assert_eq(stream.read_some(), Some(b"01234"))
    let error = transport_error(() => {
      ignore(stream.read_some())
      response
    })
    let @mttp.TransportError(kind~, phase~, ..) = error
    assert_eq(kind, Timeout(ms=150))
    assert_eq(phase, Body)
  })
}

///|
async test "with Exchange, the byte limit counts wire bytes" {
  with_h1_server(_ => @mttp.Response::new(200, body=Bytes(b"0123456789")), address => {
    let backend = @mttp_moonfetch.backend()
    defer backend.close()
    let response = backend.send(@mttp.Request::get("http://\{address}/"), {
      ..@mttp.SendOptions::default(),
      body: Exchange(max_bytes=4),
    })
    let error = transport_error(() => {
      ignore(read_text(response))
      response
    })
    let @mttp.TransportError(kind~, phase~, ..) = error
    assert_eq(kind, TooLarge(limit=4))
    assert_eq(phase, Body)
  })
}

///|
async test "cancelling a send propagates the cancellation unchanged" {
  with_tcp_server(
    conn => {
      read_head(conn)
      @async.sleep(5000)
    },
    port => {
      let backend = @mttp_moonfetch.backend()
      defer backend.close()
      // A TransportError here would escape with_timeout_opt instead of None.
      let outcome = @async.with_timeout_opt(200, () => {
        backend.send(
          @mttp.Request::get("http://127.0.0.1:\{port}/"),
          @mttp.SendOptions::default(),
        )
      })
      assert_true(outcome is None)
    },
  )
}

///|
/// The answers of the HTTP/2 tests: an echo of what arrived.
fn echo(
  verb : String,
  path : String,
  _fields : Array[(String, String)],
  body : Bytes,
) -> H2Answer {
  Reply(
    200,
    [("content-type", "text/plain")],
    @utf8.encode("\{verb} \{path} \{@utf8.decode_lossy(body[:])}"),
  )
}

///|
async test "HTTP/2 over TLS: requests share one connection" {
  with_h2_server(echo, (port, connections) => {
    let backend = @mttp_moonfetch.backend(tls=trusting())
    defer backend.close()
    let base = "https://localhost:\{port}"
    let first = backend.send(
      @mttp.Request::get("\{base}/a"),
      @mttp.SendOptions::default(),
    )
    assert_eq(
      first.attributes.get(@mttp_moonfetch.http_version),
      Some("HTTP/2"),
    )
    assert_eq(read_text(first), "GET /a ")
    let source = Pieces::{ pieces: [b"up", b"load"], next: 0, closed: false, }
    let second = backend.send(
      @mttp.Request::post("\{base}/b").body_stream(source),
      @mttp.SendOptions::default(),
    )
    assert_eq(read_text(second), "POST /b upload")
    assert_true(source.closed)
    assert_eq(connections.val, 1)
  })
}

///|
async test "HTTP/2: a stream refused before processing is unsent, so a POST is resent" {
  let calls = Ref(0)
  with_h2_server(
    (verb, path, fields, body) => {
      calls.val += 1
      if calls.val == 1 {
        Refuse
      } else {
        echo(verb, path, fields, body)
      }
    },
    (port, _) => {
      let base = "https://localhost:\{port}"
      let backend = @mttp_moonfetch.backend(tls=trusting())
      let error = transport_error(() => {
        backend.send(
          @mttp.Request::post("\{base}/once").body_bytes(b"x"),
          @mttp.SendOptions::default(),
        )
      })
      assert_true(error.is_unsent())
      calls.val = 0
      let api = @mttp_async.client(base_url=base, backend~)
      defer api.close()
      let reply = api.send(@mttp_async.post("/again").body_bytes(b"y"))
      assert_eq(reply.body, Ok("POST /again y"))
      assert_eq(calls.val, 2)
    },
  )
}

///|
async test "a certificate outside the trusted roots fails the handshake, unsent" {
  with_h2_server(echo, (port, connections) => {
    let backend = @mttp_moonfetch.backend()
    defer backend.close()
    let error = transport_error(() => {
      backend.send(
        @mttp.Request::post("https://localhost:\{port}/").body_bytes(b"x"),
        @mttp.SendOptions::default(),
      )
    })
    let @mttp.TransportError(kind~, phase~, ..) = error
    assert_eq(kind, Connect)
    assert_eq(phase, Dial)
    assert_eq(connections.val, 0)
  })
}

///|
async test "a URL moonfetch cannot send is refused before any I/O" {
  let backend = @mttp_moonfetch.backend()
  defer backend.close()
  // Another scheme, no host, and a port mttp's URL parser refuses.
  let urls = [
    "ftp://example.com/", "http:///no-host", "http://example.com:99999/",
  ]
  for url in urls {
    let error = transport_error(() => {
      backend.send(@mttp.Request::get(url), @mttp.SendOptions::default())
    })
    let @mttp.TransportError(kind~, phase~, ..) = error
    assert_eq(kind, Invalid, msg=url)
    assert_eq(phase, Pool, msg=url)
  }
}

///|
async test "a request stream that ends at once sends an empty body" {
  let seen = Ref("")
  with_h1_server(
    request => {
      seen.val = request.headers.get("content-length").unwrap_or("none")
      @mttp.Response::new(204)
    },
    address => {
      let backend = @mttp_moonfetch.backend()
      defer backend.close()
      let source = Pieces::{ pieces: [], next: 0, closed: false, }
      let response = backend.send(
        @mttp.Request::post("http://\{address}/").body_stream(source),
        @mttp.SendOptions::default(),
      )
      response.close()
      assert_eq(response.status, 204)
      assert_true(seen.val is ("none" | "0"), msg=seen.val)
      assert_true(source.closed)
    },
  )
}

///|
/// A server that sends a head promising ten bytes, five of them, and closes.
async fn closes_in_the_body(conn : @tcp.Conn) -> Unit {
  read_head(conn)
  conn.write(b"HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\n01234")
}

///|
async test "a body cut short fails in phase Body, with or without a deadline" {
  let timings : Array[@mttp.SendOptions] = [
    { timeout_ms: None, body: Exchange(max_bytes=1 << 20), },
    { timeout_ms: None, body: Stream(idle_ms=Some(5000)), },
  ]
  for options in timings {
    with_tcp_server(closes_in_the_body, port => {
      let backend = @mttp_moonfetch.backend()
      defer backend.close()
      let response = backend.send(
        @mttp.Request::get("http://127.0.0.1:\{port}/"),
        options,
      )
      let error = transport_error(() => {
        ignore(read_text(response))
        response
      })
      let @mttp.TransportError(kind~, phase~, ..) = error
      assert_eq(kind, Network)
      assert_eq(phase, Body)
      assert_false(error.is_unsent())
    })
  }
}

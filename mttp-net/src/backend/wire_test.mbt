///|
async test "hostile response heads and chunk lines have byte limits" {
  let limits = {
    ..@h1.Limits::default(),
    max_head_bytes: 100,
    max_chunk_line_bytes: 8,
  }
  for
    (wire, phase) in [
      (b"HTTP/1.1 200 OK\r\nX: " + Bytes::make(101, b'x'), @model.Phase::Head),
      (
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1;" +
        Bytes::make(9, b'x'),
        Body,
      ),
      (
        b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
        Head,
      ),
      (b"HTTP/1.1 bad\r\n\r\n", Head),
    ] {
    with_server(
      conn => {
        ignore(conn.read_until("\r\n\r\n"))
        conn.write(wire)
      },
      url => {
        let backend = @backend.H1Backend::new(head_limits=limits)
        defer backend.close()
        try
          body(
            backend.send(
              @model.Request::get(url),
              @client.RequestOptions::default(),
            ),
          )
        catch {
          @model.TransportError(kind=Protocol, phase=actual, ..) =>
            assert_eq(actual, phase)
          error => raise error
        } noraise {
          _ => fail("expected bounded parse failure")
        }
        assert_eq(backend.idle_connections(), 0)
      },
    )
  }
}

///|
priv struct Upload {
  mut bytes : Bytes?
  mut closed : Bool
}

///|
impl @model.BodyStream for Upload with fn read_some(self) {
  let bytes = self.bytes
  self.bytes = None
  bytes
}

///|
impl @model.BodyStream for Upload with fn close(self) {
  self.closed = true
}

///|
async test "known and unknown length uploads use bounded writes and valid framing" {
  let payload = Bytes::make(70000, b'x')
  for mode in 0..<3 {
    let source = { bytes: Some(payload), closed: false, }
    with_server(
      conn => {
        let head = conn.read_until("\r\n\r\n").unwrap()
        if mode == 2 {
          assert_true(head.contains("transfer-encoding: chunked"))
          assert_false(head.contains("content-length:"))
          assert_eq(conn.read_until("\r\n"), Some("10000"))
          assert_eq(conn.read_exactly(65536), payload[:65536].to_owned())
          assert_eq(conn.read_exactly(2), b"\r\n")
          assert_eq(conn.read_until("\r\n"), Some("1170"))
          assert_eq(conn.read_exactly(4464), payload[65536:].to_owned())
          assert_eq(conn.read_exactly(7), b"\r\n0\r\n\r\n")
        } else {
          assert_true(head.contains("content-length: 70000"))
          assert_eq(conn.read_exactly(70000), payload)
        }
        conn.write(b"HTTP/1.1 204 No Content\r\n\r\n")
      },
      url => {
        let backend = @backend.H1Backend::new()
        defer backend.close()
        let request = @model.Request::post(url)
        let request = match mode {
          0 => request.body_bytes(payload)
          1 => request.body_stream(source, length=70000L)
          _ => request.body_stream(source)
        }
        assert_eq(
          body(backend.send(request, @client.RequestOptions::default())),
          b"",
        )
        assert_eq(backend.idle_connections(), 1)
      },
    )
    assert_eq(source.closed, mode != 0)
  }
}

///|
async test "explicit encoding negotiation and streaming bodies retain caller ownership of limits" {
  for explicit in [false, true] {
    with_server(
      conn => {
        let head = conn.read_until("\r\n\r\n").unwrap()
        assert_true(
          head.contains(
            if explicit {
              "accept-encoding: gzip"
            } else {
              "accept-encoding: identity"
            },
          ),
        )
        assert_false(head.contains("proxy-authorization"))
        conn.write(
          b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 3\r\n\r\nraw",
        )
      },
      url => {
        let backend = @backend.H1Backend::new(max_body_bytes=1)
        defer backend.close()
        let request = @model.Request::get(url).header(
          "proxy-authorization", "private",
        )
        let request = if explicit {
          request.header("accept-encoding", "gzip")
        } else {
          request
        }
        let options = {
          ..@client.RequestOptions::default(),
          decompress: explicit,
          body_deadline: false,
        }
        let response = backend.send(request, options)
        assert_eq(response.headers.get("content-encoding"), Some("gzip"))
        assert_eq(body(response), b"raw")
      },
    )
  }
}

///|
async test "no-body framing and connection tokens honor method and protocol" {
  for
    (meth, wire, reusable) in [
      (
        @model.Method::Head,
        b"HTTP/1.1 200 OK\r\nContent-Length: 900\r\n\r\n",
        true,
      ),
      (Get, b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", true),
      (
        Get,
        b"HTTP/1.0 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n",
        true,
      ),
      (Connect, b"HTTP/1.1 200 OK\r\n\r\n", false),
      (Get, b"HTTP/1.1 101 Switching Protocols\r\n\r\n", false),
      (Get, b"HTTP/1.1 204 No Content\r\n\r\nunsolicited", false),
    ] {
    with_server(
      conn => {
        ignore(conn.read_until("\r\n\r\n"))
        conn.write(wire)
      },
      url => {
        let backend = @backend.H1Backend::new()
        defer backend.close()
        assert_eq(
          body(
            backend.send(
              @model.Request::new(meth, url),
              @client.RequestOptions::default(),
            ),
          ),
          b"",
        )
        assert_eq(backend.idle_connections(), if reusable { 1 } else { 0 })
      },
    )
  }
}

///|
async test "invalid absolute targets and body limits fail before connecting" {
  for url in ["/relative", "ftp://127.0.0.1/", "http://user:pass@127.0.0.1/"] {
    let backend = @backend.H1Backend::new()
    try
      backend.send(@model.Request::get(url), @client.RequestOptions::default())
    catch {
      @model.TransportError(kind=Invalid, phase=Pool, ..) => ()
      error => raise error
    } noraise {
      _ => fail("expected validation")
    }
  }
  for
    backend in [
      @backend.H1Backend::new(),
      @backend.H1Backend::new(max_body_bytes=-1),
    ] {
    try
      backend.send(@model.Request::get("http://127.0.0.1/"), {
        ..@client.RequestOptions::default(),
        max_body_bytes: -1,
      })
    catch {
      @model.TransportError(kind=Invalid, phase=Pool, ..) => ()
      error => raise error
    } noraise {
      _ => fail("expected body limit validation")
    }
  }
  let backend = @backend.H1Backend::new()
  try
    backend.send(
      @model.Request::get("http://127.0.0.1/").header("host", "bad host"),
      @client.RequestOptions::default(),
    )
  catch {
    @model.TransportError(kind=Invalid, phase=Pool, ..) => ()
    error => raise error
  } noraise {
    _ => fail("expected host validation")
  }
}

///|
async test "empty and truncated encoded responses retain the decoder contract" {
  for payload in [b"", b"\x1f"] {
    with_server(
      conn => {
        ignore(conn.read_until("\r\n\r\n"))
        conn.write(
          "HTTP/1.1 200 OK\r\nContent-Length: \{payload.length()}\r\nContent-Encoding: gzip\r\n\r\n",
        )
        conn.write(payload)
      },
      url => {
        let backend = @backend.H1Backend::new()
        defer backend.close()
        let response = backend.send(
          @model.Request::get(url),
          @client.RequestOptions::default(),
        )
        assert_eq(response.headers.get("content-encoding"), None)
        if payload.is_empty() {
          assert_eq(body(response), b"")
          assert_eq(backend.idle_connections(), 1)
          return
        }
        try body(response) catch {
          @model.TransportError(kind=Protocol, phase=Body, ..) => ()
          error => raise error
        } noraise {
          _ => fail("truncated gzip stream was accepted")
        }
        assert_eq(backend.idle_connections(), 0)
      },
    )
  }
}

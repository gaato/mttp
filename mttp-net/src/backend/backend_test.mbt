///|
async fn with_server(
  handler : async (@socket.Tcp) -> Unit,
  run : async (String) -> Unit,
) -> Unit {
  @async.with_timeout(5000, () => {
    let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer server.close()
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        let (conn, _) = server.accept()
        defer conn.close()
        handler(conn)
      })
      run("http://127.0.0.1:\{server.addr.port()}")
    })
  })
}

///|
async fn body(response : @model.Response) -> Bytes {
  defer response.close()
  match response.body {
    Empty => b""
    Bytes(bytes) => bytes
    Stream(stream) => @model.read_bounded(stream.take(), 1000000)
  }
}

///|
async test "H1Backend enforces the shared backend contract" {
  assert_eq(
    @testing.check_backend_contract(() => {
      @backend.AsyncBackend::new(trust_env=false)
    }),
    [],
  )
  assert_eq(
    @testing.check_backend_contract(() => {
      @backend.H1Backend::new(trust_env=false)
    }),
    [],
  )
}

///|
async test "completed responses reuse their socket and close is idempotent" {
  with_server(
    conn => {
      for _ in 0..<3 {
        ignore(conn.read_until("\r\n\r\n"))
        conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\npong")
      }
    },
    url => {
      let backend = @backend.AsyncBackend::new(
        trust_env=false,
        max_connections=1,
      )
      defer backend.close()
      for _ in 0..<3 {
        let response = backend.send(
          @model.Request::get(url),
          @client.RequestOptions::default(),
        )
        assert_eq(backend.idle_connections(), 0)
        assert_eq(body(response), b"pong")
        assert_eq(backend.idle_connections(), 1)
      }
      backend.close()
      backend.close()
      assert_eq(backend.idle_connections(), 0)
    },
  )
}

///|
async test "chunk framing consumes trailers before permitting reuse" {
  with_server(
    conn => {
      ignore(conn.read_until("\r\n\r\n"))
      for
        byte in b"HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n1;x=y\r\nc\r\n0\r\nX-Trailer: yes\r\n\r\n" {
        conn.write(Bytes::make(1, byte))
      }
    },
    url => {
      let backend = @backend.H1Backend::new(trust_env=false)
      defer backend.close()
      assert_eq(
        body(
          backend.send(
            @model.Request::get(url),
            @client.RequestOptions::default(),
          ),
        ),
        b"abc",
      )
      assert_eq(backend.idle_connections(), 1)
    },
  )
}

///|
async test "short or malformed bodies fail and discard their connection" {
  for
    wire in [
      b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabc", b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\na",
      b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nz\r\n",
    ] {
    with_server(
      conn => {
        ignore(conn.read_until("\r\n\r\n"))
        conn.write(wire)
      },
      url => {
        let backend = @backend.H1Backend::new(trust_env=false)
        defer backend.close()
        try
          body(
            backend.send(
              @model.Request::get(url),
              @client.RequestOptions::default(),
            ),
          )
        catch {
          @model.TransportError(kind=Protocol, phase=Body, ..) => ()
          error => raise error
        } noraise {
          _ => fail("expected framing failure")
        }
        assert_eq(backend.idle_connections(), 0)
      },
    )
  }
}

///|
async test "until-close and explicit response close never park sockets" {
  for
    wire in [
      b"HTTP/1.0 200 OK\r\n\r\nabc", b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 3\r\n\r\nabc",
    ] {
    with_server(
      conn => {
        ignore(conn.read_until("\r\n\r\n"))
        conn.write(wire)
      },
      url => {
        let backend = @backend.H1Backend::new(trust_env=false)
        defer backend.close()
        assert_eq(
          body(
            backend.send(
              @model.Request::get(url),
              @client.RequestOptions::default(),
            ),
          ),
          b"abc",
        )
        assert_eq(backend.idle_connections(), 0)
      },
    )
  }
  with_server(
    conn => {
      ignore(conn.read_until("\r\n\r\n"))
      conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nabc")
    },
    url => {
      let backend = @backend.H1Backend::new(trust_env=false)
      defer backend.close()
      let response = backend.send(
        @model.Request::get(url),
        @client.RequestOptions::default(),
      )
      response.close()
      response.close()
      assert_eq(backend.idle_connections(), 0)
    },
  )
}

///|
async test "automatic decoding enforces decoded rather than wire length" {
  let gzip = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\xd7\x51\xc8\x40\xa2\x00\x9f\xa1\xca\x09\x13\x00\x00\x00"
  for limit in [18, 19] {
    with_server(
      conn => {
        ignore(conn.read_until("\r\n\r\n"))
        conn.write(
          b"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 29\r\n\r\n" +
          gzip,
        )
      },
      url => {
        let backend = @backend.H1Backend::new(
          trust_env=false,
          max_body_bytes=limit,
        )
        defer backend.close()
        let response = backend.send(
          @model.Request::get(url),
          @client.RequestOptions::default(),
        )
        assert_eq(response.headers.get("content-encoding"), None)
        assert_eq(response.headers.get("content-length"), None)
        if limit == 19 {
          assert_eq(body(response), b"hello, hello, hello")
          assert_eq(backend.idle_connections(), 1)
        } else {
          try body(response) catch {
            @model.TransportError(kind=TooLarge(limit=18), phase=Body, ..) => ()
            error => raise error
          } noraise {
            _ => fail("expected decoded limit failure")
          }
          assert_eq(backend.idle_connections(), 0)
        }
      },
    )
  }
}

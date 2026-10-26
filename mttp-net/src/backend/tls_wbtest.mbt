///|
// The runtime intentionally exposes TLS server setup for internal testing;
// this loopback fixture is its only use, not a production server API.
#warnings("-alert_internal")
async test "TLS wire verifies a local root and system roots reject its self-signed certificate" {
  let certificate = "src/backend/fixtures/localhost.crt"
  let key = "src/backend/fixtures/localhost.key"
  for trusted in [false, true] {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        group.spawn_bg(no_wait=true, () => {
          let (tcp, _) = listener.accept()
          defer tcp.close()
          let tls = @tls.Tls::server(
            tcp,
            private_key_file=key,
            private_key_type=PEM,
            certificate_file=certificate,
            certificate_type=PEM,
          ) catch {
            error => {
              if trusted {
                raise error
              }
              return
            }
          }
          defer tls.close()
          if trusted {
            assert_eq(tls.read_exactly(4), b"ping")
            tls.write(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\npong")
          }
        })
        if trusted {
          let tcp = @socket.Tcp::connect_to_host(
            "127.0.0.1",
            port=listener.addr.port(),
          )
          let conn = @socket_conn.TcpDialer::new(ca_file=certificate).start_tls(
            @accepted.from_tcp(tcp),
            host="localhost",
          )
          let wire = Wire::new(conn)
          defer wire.close()
          wire.write(b"ping")
          let (_, head) = wire.head(@h1.Limits::default())
          assert_eq(head.status, 200)
          let bytes = Buffer()
          while bytes.length() < 4 {
            guard wire.read(4 - bytes.length()) is Some(part) else {
              fail("TLS body EOF")
            }
            bytes.write_bytes(part)
          }
          assert_eq(bytes.to_bytes(), b"pong")
          wire.close()
          wire.close()
        } else {
          let backend = H1Backend::new(trust_env=false)
          defer backend.close()
          try
            backend.send(
              @model.Request::get("https://127.0.0.1:\{listener.addr.port()}/"),
              @client.RequestOptions::default(),
            )
          catch {
            @model.TransportError(kind=Connect, phase=Dial, ..) => ()
            error => raise error
          } noraise {
            _ => fail("untrusted TLS accepted")
          }
          assert_eq(backend.slots.control.in_use, 0)
        }
      })
    })
  }
}

///|
// Test-only TLS servers let the tunnel exercise verified nested TLS without
// installing the fixture CA into the host's system trust store.
#warnings("-alert_internal")
async test "CONNECT carries verified end-to-end TLS over plain and TLS proxies" {
  let certificate = "src/backend/fixtures/localhost.crt"
  let key = "src/backend/fixtures/localhost.key"
  for secure_proxy in [false, true] {
    let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
    defer listener.close()
    @async.with_timeout(5000, () => {
      @async.with_task_group(group => {
        group.spawn_bg(no_wait=true, () => {
          let (tcp, _) = listener.accept()
          defer tcp.close()
          let outer = if secure_proxy {
            Some(
              @tls.Tls::server(
                tcp,
                private_key_file=key,
                private_key_type=PEM,
                certificate_file=certificate,
                certificate_type=PEM,
              ),
            )
          } else {
            None
          }
          defer (if outer is Some(tls) { tls.close() })
          let connect = (match outer {
            Some(tls) => tls.read_until("\r\n\r\n")
            None => tcp.read_until("\r\n\r\n")
          }).unwrap()
          assert_true(connect.has_prefix("CONNECT localhost:443 HTTP/1.1"))
          assert_true(connect.contains("proxy-authorization: Basic dTpw"))
          let response = b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 Connection Established\r\n\r\n"
          match outer {
            Some(tls) => tls.write(response)
            None => tcp.write(response)
          }
          let inner = match outer {
            Some(tls) =>
              @tls.Tls::server(
                tls,
                private_key_file=key,
                private_key_type=PEM,
                certificate_file=certificate,
                certificate_type=PEM,
              )
            None =>
              @tls.Tls::server(
                tcp,
                private_key_file=key,
                private_key_type=PEM,
                certificate_file=certificate,
                certificate_type=PEM,
              )
          }
          defer inner.close()
          let request = inner.read_until("\r\n\r\n").unwrap()
          assert_false(request.contains("proxy-authorization:"))
          assert_true(request.contains("authorization: Bearer origin"))
          inner.write(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\npong")
        })
        let wire = dial_wire("127.0.0.1", listener.addr.port(), false)
        defer wire.close()
        if secure_proxy {
          wire.start_tls(
            @socket_conn.TcpDialer::new(ca_file=certificate),
            "localhost",
          )
        }
        let origin = target(@model.Request::get("https://localhost"))
        open_tunnel(
          wire,
          origin,
          { origin: "http://proxy", authorization: Some("Basic dTpw"), },
          None,
          @h1.Limits::default(),
        )
        wire.start_tls(
          @socket_conn.TcpDialer::new(ca_file=certificate),
          "localhost",
        )
        wire.write(
          b"GET / HTTP/1.1\r\nhost: localhost\r\nauthorization: Bearer origin\r\n\r\n",
        )
        assert_eq(wire.head(@h1.Limits::default()).1.status, 200)
        let body = Buffer()
        while body.length() < 4 {
          guard wire.read(4 - body.length()) is Some(bytes) else {
            fail("tunnel EOF")
          }
          body.write_bytes(bytes)
        }
        assert_eq(body.to_bytes(), b"pong")
        wire.close()
        assert_true(wire.closed)
        assert_eq(wire.conn.read(max_len=1), None)
        let failed = try {
          wire.conn.write(b"x")
          false
        } catch {
          @model.TransportError(kind=Network, phase=Unknown, ..) => true
          _ => false
        }
        assert_true(failed)
      })
    })
  }
}

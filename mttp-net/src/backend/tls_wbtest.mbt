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
          let tls = @tls.Tls::client(
            tcp,
            host="localhost",
            trust=CustomPemFile(certificate),
          )
          let wire = Wire::{ tcp, tls: Some(tls), pending: b"", closed: false, }
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
          let backend = H1Backend::new()
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
          assert_eq(backend.slots.in_use, 0)
        }
      })
    })
  }
}

///|
async test "NO_PROXY routes direct and forwarded requests on distinct reusable connections" {
  let origin = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer origin.close()
  let proxy = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer proxy.close()
  let backend = {
    ..H1Backend::new(trust_env=false),
    proxies: configure_proxies(
      None,
      trust_env=true,
      env_of([
        ("http_proxy", "127.0.0.1:\{proxy.addr.port()}"),
        ("no_proxy", "127.0.0.1"),
      ]),
    ),
  }
  defer backend.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group(group => {
      for
        (server, prefix) in [
          (origin, "GET /"),
          (proxy, "GET http://localhost:"),
        ] {
        group.spawn_bg(no_wait=true, () => {
          let (conn, _) = server.accept()
          defer conn.close()
          for _ in 0..<2 {
            assert_true(conn.read_until("\r\n\r\n").unwrap().has_prefix(prefix))
            conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
          }
        })
      }
      for _ in 0..<2 {
        for host in ["127.0.0.1", "localhost"] {
          backend
          .send(
            @model.Request::get("http://\{host}:\{origin.addr.port()}/"),
            @client.RequestOptions::default(),
          )
          .close()
        }
      }
      assert_eq(backend.idle_connections(), 2)
      assert_eq(backend.slots.in_use, 0)
    })
  })
}

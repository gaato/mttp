///|
async test "HTTP proxies get absolute targets and only configured proxy credentials" {
  with_server(
    conn => {
      let text = conn.read_until("\r\n\r\n").unwrap()
      assert_true(
        text.has_prefix("GET http://destination.invalid:80/path?q=1 HTTP/1.1"),
      )
      assert_true(text.contains("host: destination.invalid:80"))
      assert_true(text.contains("proxy-authorization: Basic dXNlcjpwYXNz"))
      assert_false(text.contains("wrong-credential"))
      conn.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
    },
    proxy => {
      let proxy = proxy.replace_all(old="http://", new="http://user:pass@")
      let backend = @backend.H1Backend::new(trust_env=false, proxy~)
      defer backend.close()
      let request = @model.Request::get(
        "http://destination.invalid/path?q=1#ignored",
      ).header("proxy-authorization", "wrong-credential")
      assert_eq(
        body(backend.send(request, @client.RequestOptions::default())),
        b"ok",
      )
    },
  )
}

///|
async test "CONNECT refusals malformed heads and excess bytes are bounded in Dial" {
  let cases : Array[(Bytes, @model.Kind)] = [
    (b"HTTP/1.1 407 Authentication Required\r\n\r\n", Proxy(status=407)),
    (b"HTTP/1.1 200 OK\r\nX: " + Bytes::make(101, b'x'), Protocol),
    (b"HTTP/1.1 200 OK\r\n\r\nunsolicited", Protocol),
    (b"HTTP/1.1 101 Switching Protocols\r\n\r\n", Protocol),
    (b"HTTP/1.1 200 OK\r\n\r\n", Connect),
    (b"", Network),
  ]
  for (wire, expected) in cases {
    with_server(
      conn => {
        let text = conn.read_until("\r\n\r\n").unwrap()
        assert_true(text.has_prefix("CONNECT destination.invalid:443 HTTP/1.1"))
        assert_true(text.contains("host: destination.invalid:443"))
        assert_true(text.contains("user-agent: tunnel-test"))
        assert_false(text.contains("authorization:"))
        conn.write(wire)
      },
      proxy => {
        let backend = @backend.H1Backend::new(trust_env=false, proxy~, head_limits={
          ..@h1.Limits::default(),
          max_head_bytes: 100,
        })
        defer backend.close()
        try
          backend.send(
            @model.Request::get("https://destination.invalid/")
            .bearer("origin-only")
            .header("user-agent", "tunnel-test"),
            @client.RequestOptions::default(),
          )
        catch {
          @model.TransportError(kind~, phase=Dial, ..) =>
            assert_eq(kind, expected)
          error => raise error
        } noraise {
          _ => fail("proxy failure accepted")
        }
        assert_eq(backend.idle_connections(), 0)
      },
    )
  }
}

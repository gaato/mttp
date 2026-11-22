///|
/// A backend whose every request goes through the test server's proxy,
/// except those to the hosts in `no_proxy`.
async fn proxied(server : Server, no_proxy~ : String = "") -> CurlBackend {
  CurlBackend::new(trust=PemFile(testdata("root.pem")), proxy={
    http: Some(server.proxy),
    https: Some(server.proxy),
    no_proxy,
  })
}

///|
async test "https through a proxy's CONNECT tunnel is still h2" {
  with_server(server => {
    let backend = proxied(server)
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.tls + "/hello"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(response.attributes.get(@mttp_core.protocol), Some("h2"))
    assert_eq(text(response), "hello")
  })
}

///|
async test "http goes to the proxy in absolute form, unresolved" {
  with_server(server => {
    let backend = proxied(server)
    defer backend.close()
    // echo.invalid resolves nowhere: only the proxy can answer for it.
    let response = backend.send(
      @mttp_core.Request::get("http://echo.invalid/hello?x=1"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(
      response.headers.get("x-target"),
      Some("http://echo.invalid/hello?x=1"),
    )
    assert_eq(text(response), "via proxy")
  })
}

///|
async test "a proxy refusing the tunnel is Proxy(407) in Dial, unsent" {
  with_server(server => {
    let backend = proxied(server)
    defer backend.close()
    let e = send_error(
      backend,
      @mttp_core.Request::post("https://deny.invalid/x"),
    )
    guard e is @mttp_core.TransportError(kind=Proxy(status=407), phase=Dial, ..) else {
      fail("unexpected \{e.to_repr()}")
    }
    assert_true(e.is_unsent())
  })
}

///|
async test "no_proxy hosts are reached directly" {
  with_server(server => {
    let backend = proxied(server, no_proxy="localhost")
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.tls + "/hello"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(text(response), "hello")
    // The CONNECT-less path: a direct TLS connection gets h2 by ALPN too,
    // so the proof is that a proxy refusing everything would not matter.
    let refusing = CurlBackend::new(trust=PemFile(testdata("root.pem")), proxy={
      http: Some("http://127.0.0.1:1"),
      https: Some("http://127.0.0.1:1"),
      no_proxy: "localhost",
    })
    defer refusing.close()
    let direct = refusing.send(
      @mttp_core.Request::get(server.tls + "/hello"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(text(direct), "hello")
  })
}

///|
async test "GET over h2c" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.h2c + "/hello"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(response.status, 200)
    assert_eq(response.attributes.get(@mttp_core.protocol), Some("h2"))
    assert_eq(response.headers.get("content-type"), Some("text/plain"))
    assert_eq(text(response), "hello")
  })
}

///|
async test "GET over TLS picks h2 by ALPN" {
  with_server(server => {
    let backend = tls_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.tls + "/hello"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(response.status, 200)
    assert_eq(response.attributes.get(@mttp_core.protocol), Some("h2"))
    assert_eq(text(response), "hello")
  })
}

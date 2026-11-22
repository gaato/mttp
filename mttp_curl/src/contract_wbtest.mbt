///|
async test "gaato/mttp's Client over the backend, with Decompress as the network backend has it" {
  with_server(server => {
    let backend = @codings.Decompress::new(tls_backend())
    let client = @mttp.client(base_url=server.tls, backend~)
    defer client.close()
    let redirected = client.send(@mttp.get("/redirect"))
    assert_eq(redirected.status, 200)
    assert_eq(redirected.body, Ok("hello"))
    let decoded = client.send(@mttp.get("/gzip"))
    assert_eq(decoded.body, Ok("hello gzip"))
  })
}

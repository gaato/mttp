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

///|
async test "backend(): the Client decodes, and its events carry the phases" {
  with_server(server => {
    let phases = []
    let client = @mttp.client(
      base_url=server.tls,
      backend=backend(
        trust=PemFile(testdata("root.pem")),
        proxy=@h1client.ProxyConfig::none(),
      ),
      events=event => if event is Phase(phase~, ..) { phases.push(phase) },
    )
    defer client.close()
    let decoded = client.send(@mttp.get("/gzip"))
    assert_eq(decoded.body, Ok("hello gzip"))
    assert_true(phases.contains(TlsDone))
    assert_true(phases.contains(FirstByte))
  })
}

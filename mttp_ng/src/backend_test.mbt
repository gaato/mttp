///|
async test "backend() sends through the HTTP/1 client to an http URL" {
  // Port 1 refuses connections: the failure is the dial's, in phase Dial,
  // after Decompress and H2Backend passed the request on.
  let b = @mttp_ng.backend(config={
    ..@h1client.ClientConfig::default(),
    proxy: @h1client.ProxyConfig::none(),
  })
  defer b.close()
  try
    b.send(
      @mttp_core.Request::get("http://127.0.0.1:1/"),
      @mttp_core.SendOptions::default(),
    )
  catch {
    @mttp_core.TransportError(kind~, phase~, ..) => {
      assert_eq(kind, Connect)
      assert_eq(phase, Dial)
    }
  } noraise {
    response => fail("port 1 answered: \{response.status}")
  }
}

// Live exchanges with public servers, other implementations than the
// module's own and Node's, for scripts/gates.sh ng-live only: they need the
// internet, so they run when MTTP_NG_LIVE is set and return at once
// otherwise.

///|
fn live() -> Bool {
  @env.get_env_var("MTTP_NG_LIVE") is Some(_)
}

///|
async test "live: HTTP/2 to www.cloudflare.com" {
  guard live() else { return }
  let backend = @mttp_ng.backend(config={
    ..@h1client.ClientConfig::default(),
    proxy: @h1client.ProxyConfig::none(),
  })
  defer backend.close()
  let response = backend.send(
    @mttp_core.Request::get("https://www.cloudflare.com/cdn-cgi/trace"),
    @mttp_core.SendOptions::default(),
  )
  assert_eq(response.status, 200)
  assert_eq(response.attributes.get(@mttp_core.protocol), Some("h2"))
  let body = @utf8.decode_lossy(response.body.read_all(max=1 << 20))
  assert_true(body.contains("http=http/2"))
}

///|
async test "live: HTTP/3 to cloudflare-quic.com, a whole page" {
  guard live() else { return }
  let backend = @mttp_ng.backend(http3=true, config={
    ..@h1client.ClientConfig::default(),
    proxy: @h1client.ProxyConfig::none(),
  })
  defer backend.close()
  let response = backend.send(
    @mttp_core.Request::get("https://cloudflare-quic.com/"),
    @mttp_core.SendOptions::default(),
  )
  assert_eq(response.status, 200)
  // Not h2: the QUIC handshake finished within its second.
  assert_eq(response.attributes.get(@mttp_core.protocol), Some("h3"))
  let body = @utf8.decode_lossy(response.body.read_all(max=4 << 20))
  assert_true(body.contains("</html>"))
}

///|
async test "live: PemFile trusts the file's roots only, not the system's" {
  guard live() else { return }
  // The tests' own root: no public site is under it.
  let backend = @mttp_ng.backend(
    http3=true,
    trust=PemFile(testdata("root.pem")),
    config={
      ..@h1client.ClientConfig::default(),
      proxy: @h1client.ProxyConfig::none(),
    },
  )
  defer backend.close()
  let failed = try {
    backend.send(
      @mttp_core.Request::get("https://www.cloudflare.com/cdn-cgi/trace"),
      @mttp_core.SendOptions::default(),
    )
    |> ignore
    None
  } catch {
    e => Some(e)
  }
  guard failed is Some(@mttp_core.TransportError(kind=Connect, phase=Dial, ..)) else {
    fail("a system-trusted site was accepted under PemFile")
  }
}

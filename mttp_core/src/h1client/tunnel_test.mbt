// `https_tunnel`: the byte stream to an https origin through the proxy this
// client would use for it, for a client that runs its own TLS inside.

///|
test "https_tunnel opens the proxy's CONNECT tunnel and leaves TLS to the caller" {
  let config = proxied(
    @h1client.ProxyConfig::fixed("http://user:pass@proxy.test:3128"),
  )
  let h = Harness::new(config~)
  let conn = h.scripted([Chunk(b"HTTP/1.1 200 Connection established\r\n\r\n")])
  h.run(() => {
    let tunnel = @h1client.https_tunnel(
      h.dialer,
      config,
      url="https://origin.test/path",
      agent="test-agent",
    )
    guard tunnel is Some(tunnel) else { fail("no tunnel") }
    tunnel.close()
    h.finish()
  })
  assert_eq(h.dialer.dialed, [("proxy.test", 3128)])
  // The origin's TLS is the caller's.
  assert_eq(h.dialer.tls_hosts, [])
  assert_eq(conn.written(), [
    b"CONNECT origin.test:443 HTTP/1.1\r\nhost: origin.test:443\r\nproxy-authorization: Basic dXNlcjpwYXNz\r\nuser-agent: test-agent\r\n\r\n",
  ])
}

///|
test "https_tunnel is None where the origin goes direct" {
  for
    config in [
      @h1client.ClientConfig::default(),
      proxied({
        ..@h1client.ProxyConfig::fixed("http://proxy.test:3128"),
        no_proxy: "origin.test",
      }),
    ] {
    let h = Harness::new(config~)
    h.run(() => {
      let tunnel = @h1client.https_tunnel(
        h.dialer,
        config,
        url="https://origin.test/",
      )
      assert_true(tunnel is None)
      h.finish()
    })
    assert_eq(h.dialer.dialed, [])
  }
}

///|
test "https_tunnel fails as a send through the proxy would" {
  let config = proxied(@h1client.ProxyConfig::fixed("http://proxy.test:3128"))
  let h = Harness::new(config~)
  ignore(
    h.scripted([Chunk(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")]),
  )
  h.run(() => {
    let refused = try
      @h1client.https_tunnel(h.dialer, config, url="https://origin.test/")
    catch {
      @mttp_core.TransportError(kind~, phase~, ..) => Some((kind, phase))
    } noraise {
      _ => None
    }
    assert_eq(refused, Some((Proxy(status=407), Dial)))
    let invalid = try
      @h1client.https_tunnel(h.dialer, config, url="http://origin.test/")
    catch {
      @mttp_core.TransportError(kind~, phase~, ..) => Some((kind, phase))
    } noraise {
      _ => None
    }
    assert_eq(invalid, Some((Invalid, Pool)))
    h.finish()
  })
}

///|
test "https_tunnel goes through a SOCKS5 proxy too, by name" {
  let config = proxied(@h1client.ProxyConfig::fixed("socks5h://proxy.test"))
  let h = Harness::new(config~)
  let conn = h.scripted([
    Chunk(b"\x05\x00\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00"),
  ])
  h.run(() => {
    let tunnel = @h1client.https_tunnel(
      h.dialer,
      config,
      url="https://origin.test/",
    )
    guard tunnel is Some(tunnel) else { fail("no tunnel") }
    tunnel.close()
    h.finish()
  })
  assert_eq(h.dialer.dialed, [("proxy.test", 1080)])
  assert_eq(h.dialer.tls_hosts, [])
  // A CONNECT for the name, which the proxy resolves (ATYP 3), port 443.
  assert_eq(conn.written()[1], b"\x05\x01\x00\x03\x0borigin.test\x01\xbb")
}

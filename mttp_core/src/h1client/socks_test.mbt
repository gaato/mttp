///|
test "socks5h uses proxy DNS origin form credentials and TLS at every transport split" {
  let transcript = b"\x05\x02\x01\x00\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x50"
  for secure in [false, true] {
    for split in 0..<=transcript.length() {
      let h = Harness::new(
        config=proxied(@h1client.ProxyConfig::fixed("socks5h://u:p@proxy.test")),
      )
      let steps = []
      if split > 0 {
        steps.push(@sim.ReadStep::Chunk(transcript[:split].to_owned()))
      }
      steps.push(Chunk(transcript[split:].to_owned() + ok("inside")))
      let conn = h.scripted(steps)
      h.run(() => {
        let scheme = if secure { "https" } else { "http" }
        assert_eq(
          fetch(
            h.client,
            @mttp_core.Request::get(scheme + "://origin.test/path").header(
              "proxy-authorization", "wrong",
            ),
          ),
          "inside",
        )
        h.finish()
      })
      assert_eq(h.dialer.dialed, [("proxy.test", 1080)])
      assert_eq(h.dialer.tls_hosts, if secure { ["origin.test"] } else { [] })
      assert_eq(conn.written(), [
        b"\x05\x01\x02",
        b"\x01\x01u\x01p",
        b"\x05\x01\x00\x03\x0borigin.test" +
        (if secure { b"\x01\xbb" } else { b"\x00\x50" }),
        b"GET /path HTTP/1.1\r\nhost: origin.test\r\n\r\n",
      ])
    }
  }
}

///|
test "socks5h environment selection and NO_PROXY bypass use the HTTP proxy rules" {
  let env = { "ALL_PROXY": "socks5h://proxy.test", "NO_PROXY": "direct.test" }
  let proxy = @h1client.ProxyConfig::from_env(name => env.get(name))
  let h = Harness::new(config=proxied(proxy))
  let direct = h.scripted([Chunk(ok("direct"))])
  let tunnel = h.scripted([
    Chunk(b"\x05\x00\x05\x00\x00\x03\x01x\x00\x50" + ok("proxied")),
  ])
  h.run(() => {
    assert_eq(
      fetch(h.client, @mttp_core.Request::get("http://direct.test/")),
      "direct",
    )
    assert_eq(
      fetch(h.client, @mttp_core.Request::get("http://origin.test/")),
      "proxied",
    )
    h.finish()
  })
  assert_eq(h.dialer.dialed, [("direct.test", 80), ("proxy.test", 1080)])
  assert_eq(direct.written(), [b"GET / HTTP/1.1\r\nhost: direct.test\r\n\r\n"])
  assert_eq(tunnel.written()[0], b"\x05\x01\x00")
}

///|
test "truncated SOCKS handshakes fail Connect Dial close and never start TLS" {
  let transcript = b"\x05\x02\x01\x00\x05\x00\x00\x04" + Bytes::make(18, 0)
  for end in 0..<transcript.length() {
    let h = Harness::new(
      config=proxied(@h1client.ProxyConfig::fixed("socks5h://u:p@proxy.test")),
    )
    let steps = []
    if end > 0 {
      steps.push(@sim.ReadStep::Chunk(transcript[:end].to_owned()))
    }
    steps.push(Eof)
    let conn = h.scripted(steps)
    h.run(() => {
      assert_eq(
        failing(() => {
          ignore(
            fetch(h.client, @mttp_core.Request::get("https://origin.test/")),
          )
        }),
        (Connect, Dial),
      )
      h.finish()
    })
    assert_eq(conn.closes(), 1)
    assert_eq(h.dialer.tls_hosts, [])
  }
}

///|
test "the Dial deadline bounds a stalled SOCKS negotiation and closes the tunnel" {
  let h = Harness::new(config={
    ..proxied(@h1client.ProxyConfig::fixed("socks5h://proxy.test")),
    connect_timeout_ms: Some(50),
  })
  let conn = h.scripted([Wait(h.coordination.signal())])
  h.run(() => {
    assert_eq(
      failing(() => {
        ignore(fetch(h.client, @mttp_core.Request::get("https://origin.test/")))
      }),
      (Timeout(ms=50), Dial),
    )
    h.finish()
  })
  assert_eq(conn.closes(), 1)
  assert_eq(h.dialer.tls_hosts, [])
}

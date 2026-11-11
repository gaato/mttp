///|
fn proxied(proxy : @h1client.ProxyConfig) -> @h1client.ClientConfig {
  { ..@h1client.ClientConfig::default(), proxy, }
}

///|
test "a forward proxy gets the absolute target and only its own credentials" {
  let h = Harness::new(
    config=proxied(
      @h1client.ProxyConfig::fixed("http://user:pass@proxy.test:3128"),
    ),
  )
  let conn = h.scripted([Chunk(ok("ok"))])
  h.run(() => {
    let request = @mttp.Request::get("http://destination.test/path?q=1#ignored").header(
      "proxy-authorization", "wrong-credential",
    )
    assert_eq(fetch(h.client, request), "ok")
    h.finish()
  })
  assert_eq(h.dialer.dialed, [("proxy.test", 3128)])
  assert_eq(h.dialer.tls_hosts, [])
  assert_eq(conn.written(), [
    b"GET http://destination.test/path?q=1 HTTP/1.1\r\nproxy-authorization: Basic dXNlcjpwYXNz\r\nhost: destination.test\r\n\r\n",
  ])
}

///|
test "a direct request never carries the caller's Proxy-Authorization" {
  let h = Harness::new(
    config=proxied({
      ..@h1client.ProxyConfig::fixed("http://u:p@proxy.test:1"),
      no_proxy: "direct.test",
    }),
  )
  let conn = h.scripted([Chunk(ok("ok"))])
  h.run(() => {
    let request = @mttp.Request::get("http://direct.test/").header(
      "proxy-authorization", "private",
    )
    assert_eq(fetch(h.client, request), "ok")
    h.finish()
  })
  assert_eq(h.dialer.dialed, [("direct.test", 80)])
  assert_eq(conn.written(), [b"GET / HTTP/1.1\r\nhost: direct.test\r\n\r\n"])
}

///|
test "https requests go through a CONNECT tunnel with TLS end to end" {
  for proxy in ["http://u:p@proxy.test:3128", "https://u:p@proxy.test:8443"] {
    let h = Harness::new(config=proxied(@h1client.ProxyConfig::fixed(proxy)))
    let conn = h.scripted([
      Chunk(b"HTTP/1.1 200 Connection Established\r\n\r\n"),
      Chunk(ok("inside")),
    ])
    h.run(() => {
      let request = @mttp.Request::get("https://origin.test/secret")
        .header("user-agent", "tunnel-test")
        .bearer("origin-only")
      assert_eq(fetch(h.client, request), "inside")
      // The tunnelled connection is parked for the same origin and proxy.
      assert_eq(h.client.idle_connections(), 1)
      h.finish()
    })
    let secure = proxy.has_prefix("https")
    assert_eq(h.dialer.dialed, [
      ("proxy.test", if secure { 8443 } else { 3128 }),
    ])
    // At most two TLS layers: the proxy's, then the origin's in the tunnel.
    assert_eq(
      h.dialer.tls_hosts,
      if secure {
        ["proxy.test", "origin.test"]
      } else {
        ["origin.test"]
      },
    )
    let writes = conn.written()
    assert_eq(
      writes[0],
      b"CONNECT origin.test:443 HTTP/1.1\r\nhost: origin.test:443\r\nproxy-authorization: Basic dTpw\r\nuser-agent: tunnel-test\r\n\r\n",
    )
    // The request inside goes in origin form, without proxy credentials.
    assert_eq(
      writes[1],
      b"GET /secret HTTP/1.1\r\nuser-agent: tunnel-test\r\nauthorization: Bearer origin-only\r\nhost: origin.test\r\n\r\n",
    )
  }
}

///|
test "CONNECT refusals, malformed answers and excess bytes fail in phase Dial" {
  let rows : Array[(Bytes, @mttp.Kind)] = [
    (b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n", Proxy(status=407)),
    (
      b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n",
      Proxy(status=502),
    ),
    (b"HTTP/1.1 200 OK\r\n\r\nunsolicited", Protocol),
    (b"HTTP/1.1 101 Switching Protocols\r\n\r\n", Protocol),
    (b"HTTP/1.1 nope\r\n\r\n", Protocol),
    (b"HTTP/1.1 2", Network),
    (b"", Network),
  ]
  for row in rows {
    let (wire, expected) = row
    let h = Harness::new(
      config=proxied(@h1client.ProxyConfig::fixed("http://proxy.test:3128")),
    )
    let conn = h.scripted([Chunk(wire), Eof])
    h.run(() => {
      let error = failing(() => {
        ignore(fetch(h.client, @mttp.Request::get("https://origin.test/")))
      })
      assert_eq(error, (expected, Dial), msg="\{wire}")
      h.finish()
    })
    assert_eq(conn.closes(), 1)
    // Nothing reached the origin: no TLS session was started.
    assert_eq(h.dialer.tls_hosts, [])
  }
  // A failed TLS upgrade inside the tunnel is a Dial failure too.
  let h = Harness::new(
    config=proxied(@h1client.ProxyConfig::fixed("http://proxy.test:3128")),
  )
  let conn = h.scripted([Chunk(b"HTTP/1.1 200 OK\r\n\r\n")])
  h.dialer.tls_failure = Some(
    @mttp.TransportError(kind=Connect, phase=Dial, detail="bad certificate"),
  )
  h.run(() => {
    assert_eq(
      failing(() => {
        ignore(fetch(h.client, @mttp.Request::get("https://origin.test/")))
      }),
      (Connect, Dial),
    )
  })
  assert_eq(conn.closes(), 1)
}

///|
test "the proxy's CONNECT answer is read within the head limits" {
  let limits = { ..@h1.Limits::default(), max_head_bytes: 64, }
  let head = "HTTP/1.1 200 OK\r\nX: "
  for total in [64, 65] {
    let h = Harness::new(config={
      ..proxied(@h1client.ProxyConfig::fixed("http://proxy.test:3128")),
      head_limits: limits,
    })
    ignore(
      h.scripted([Chunk(padded(head, total, "\r\n\r\n")), Chunk(ok("in"))]),
    )
    h.run(() => {
      let result = Ok(
        fetch(h.client, @mttp.Request::get("https://origin.test/")),
      ) catch {
        error => Err(kind_phase(error))
      }
      assert_eq(
        result,
        if total == 64 {
          Ok("in")
        } else {
          Err((Protocol, Dial))
        },
      )
      h.finish()
    })
  }
  // Informational answers are skipped, at most 16 of them.
  for count in [16, 17] {
    let h = Harness::new(
      config=proxied(@h1client.ProxyConfig::fixed("http://proxy.test:3128")),
    )
    let informational = @utf8.encode(
      "HTTP/1.1 100 Continue\r\n\r\n".repeat(count),
    )
    ignore(
      h.scripted([
        Chunk(informational + b"HTTP/1.1 200 OK\r\n\r\n"),
        Chunk(ok("in")),
      ]),
    )
    h.run(() => {
      let result = Ok(
        fetch(h.client, @mttp.Request::get("https://origin.test/")),
      ) catch {
        error => Err(kind_phase(error))
      }
      assert_eq(
        result,
        if count == 16 {
          Ok("in")
        } else {
          Err((Protocol, Dial))
        },
      )
      h.finish()
    })
  }
}

///|
test "a CONNECT the caller sends keeps its authority through a forward proxy" {
  let h = Harness::new(
    config=proxied(@h1client.ProxyConfig::fixed("http://proxy.test:3128")),
  )
  let conn = h.scripted([Chunk(b"HTTP/1.1 200 Connection Established\r\n\r\n")])
  h.run(() => {
    let response = h.client.send(
      @mttp.Request::new(Connect, "http://destination.test:80"),
      exchange(),
    )
    assert_eq(response.status, 200)
    response.close()
    // A tunnel is never parked.
    assert_eq(h.client.idle_connections(), 0)
    h.finish()
  })
  assert_eq(conn.written(), [
    b"CONNECT destination.test:80 HTTP/1.1\r\nhost: destination.test:80\r\n\r\n",
  ])
}

///|
test "NO_PROXY routes direct and proxied requests on distinct reusable connections" {
  let h = Harness::new(
    config=proxied({
      ..@h1client.ProxyConfig::fixed("http://proxy.test:3128"),
      no_proxy: "local.test",
    }),
  )
  let proxy = h.peer()
  let direct = h.peer()
  h.run(() => {
    let servers = [
      h.driver.spawn(() => {
        let seen = proxy.serve(ok("via proxy"))
        assert_eq(seen.length(), 2)
        assert_eq(seen[0].head.target, "http://remote.test/")
      }),
      h.driver.spawn(() => {
        let seen = direct.serve(ok("direct"))
        assert_eq(seen.length(), 2)
        assert_eq(seen[0].head.target, "/")
      }),
    ]
    for _ in 0..<2 {
      assert_eq(
        fetch(h.client, @mttp.Request::get("http://remote.test/")),
        "via proxy",
      )
      assert_eq(
        fetch(h.client, @mttp.Request::get("http://local.test/")),
        "direct",
      )
    }
    assert_eq(h.client.idle_connections(), 2)
    h.finish()
    for server in servers {
      ignore(server.wait())
    }
  })
  assert_eq(h.dialer.dialed, [("proxy.test", 3128), ("local.test", 80)])
}

///|
test "an unusable proxy setting fails before any dial" {
  let h = Harness::new(
    config=proxied({
      http: Some("socks5://proxy.test:1080"),
      https: None,
      no_proxy: "",
    }),
  )
  ignore(h.scripted([Chunk(ok("direct"))]))
  h.run(() => {
    assert_eq(
      failing(() => {
        ignore(fetch(h.client, @mttp.Request::get("http://a.test/")))
      }),
      (Protocol, Pool),
    )
    // The other scheme has no proxy and goes direct.
    assert_eq(fetch(h.client, @mttp.Request::get("https://a.test/")), "direct")
    h.finish()
  })
  assert_eq(h.dialer.dialed, [("a.test", 443)])
}

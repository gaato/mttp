///|
test "fresh resend of an Upgrade keeps stale_resend and leaves the slot reclaimable" {
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    max_connections: Some(1),
  })
  let stale = h.scripted([
    Chunk(ok("")),
    Failure(@mttp_core.TransportError(kind=Network, phase=Head, detail="stale")),
  ])
  let conn = h.scripted([Chunk(b"HTTP/1.1 101 Switching Protocols\r\n\r\n")])
  let _ = h.scripted([Chunk(ok(""))])
  h.run(() => {
    h.client
    .send(@mttp_core.Request::get("http://example.test/"), exchange())
    .close()
    let response = h.client.send(upgrade_request(), exchange())
    assert_eq(response.attributes.get(@h1client.stale_resend), Some(true))
    response.attributes.get(@rt.upgraded).unwrap().take_conn().unwrap().0.close()
    h.client.send(upgrade_request(), exchange()).close()
    assert_eq(stale.closes(), 1)
    assert_eq(conn.closes(), 1)
    h.finish()
  })
}

///|
test "backend close reclaims unclaimed upgrades and never closes claimed ones" {
  for claim in [false, true] {
    let h = Harness::new(config={
      ..@h1client.ClientConfig::default(),
      max_connections: Some(1),
    })
    let conn = h.scripted([Chunk(b"HTTP/1.1 101 Switching Protocols\r\n\r\n")])
    h.run(() => {
      let response = h.client.send(upgrade_request(), exchange())
      let upgrade = response.attributes.get(@rt.upgraded).unwrap()
      let taken = if claim {
        Some(upgrade.take_conn().unwrap().0)
      } else {
        None
      }
      h.client.close()
      h.client.close()
      if taken is Some(taken) {
        assert_eq(conn.closes(), 0)
        taken.close()
      }
      assert_eq(conn.closes(), 1)
      assert_true(upgrade.take_conn() is None)
      h.finish()
    })
  }
}

///|
fn upgrade_request(
  url~ : String = "http://example.test/",
) -> @mttp_core.Request {
  @mttp_core.Request::get(url)
  .header("connection", "keep-alive, UpGrAdE")
  .header("upgrade", "websocket")
}

///|
test "101 transfers pending bytes once and retains its slot until exactly one close" {
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    max_connections: Some(1),
    max_connections_per_origin: Some(1),
  })
  let pending : Bytes = [0x82, 0x04, 0, 0xff, 0x80, 0x01]
  let conn = h.scripted([
    Chunk(
      b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n" +
      pending,
    ),
    Chunk(b"next"),
  ])
  let _ = h.scripted([Chunk(b"HTTP/1.1 101 Switching Protocols\r\n\r\n")])
  let _ = h.scripted([Chunk(ok(""))])
  h.run(() => {
    let response = h.client.send(upgrade_request(), exchange())
    response.close()
    assert_eq(conn.closes(), 0)
    assert_eq(h.client.idle_connections(), 0)
    let upgrade = response.attributes.get(@rt.upgraded).unwrap()
    let (taken, bytes) = upgrade.take_conn().unwrap()
    assert_eq(bytes, pending)
    assert_true(upgrade.take_conn() is None)
    let done = Ref(false)
    let next : Ref[&@rt.Conn?] = Ref(None)
    let child = h.driver.spawn(() => {
      let response = h.client.send(upgrade_request(), exchange())
      response.close()
      next.val = Some(
        response.attributes.get(@rt.upgraded).unwrap().take_conn().unwrap().0,
      )
      done.val = true
    })
    h.driver.pause()
    assert_false(done.val)
    assert_eq(h.dialer.dialed.length(), 1)
    assert_eq(taken.read(max_len=4), Some(b"next"))
    taken.close()
    ignore(child.wait())
    assert_true(done.val)
    assert_eq(conn.closes(), 1)
    // A duplicate close must not release the second upgrade's live slot.
    taken.close()
    let third_done = Ref(false)
    let third = h.driver.spawn(() => {
      h.client.send(upgrade_request(), exchange()).close()
      third_done.val = true
    })
    h.driver.pause()
    assert_false(third_done.val)
    assert_eq(h.dialer.dialed.length(), 2)
    next.val.unwrap().close()
    ignore(third.wait())
    assert_true(third_done.val)
    h.finish()
  })
}

///|
test "unrequested 101 refuses missing Connection upgrade or missing Upgrade in Head" {
  for
    headers in [
      @mttp_core.Headers::empty(),
      @mttp_core.Headers::of([("upgrade", "websocket")]),
      @mttp_core.Headers::of([("connection", "upgrade")]),
      @mttp_core.Headers::of([
        ("connection", "xupgrade"),
        ("upgrade", "websocket"),
      ]),
    ] {
    let h = Harness::new()
    let conn = h.scripted([
      Chunk(b"HTTP/1.1 101 Switching Protocols\r\n\r\nignored"),
    ])
    h.run(() => {
      let error = failing(() => {
        ignore(h.client.send({ ..upgrade_request(), headers, }, exchange()))
      })
      assert_eq(error, (Protocol, Head))
      assert_eq(conn.closes(), 1)
      h.finish()
    })
  }
}

///|
test "proxy CONNECT then 101 hands over bytes with TLS only for secure origins" {
  for secure in [false, true] {
    let h = Harness::new(config={
      ..@h1client.ClientConfig::default(),
      proxy: @h1client.ProxyConfig::fixed("http://proxy.test:3128"),
    })
    let forwarded = if !secure {
      Some(h.scripted([Chunk(ok(""))]))
    } else {
      None
    }
    let conn = h.scripted([
      Chunk(b"HTTP/1.1 200 Connection Established\r\n\r\n"),
      Chunk(
        b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n\x81\x00",
      ),
    ])
    h.run(() => {
      if forwarded is Some(forwarded) {
        h.client
        .send(@mttp_core.Request::get("http://example.test/"), exchange())
        .close()
        assert_eq(h.client.idle_connections(), 1)
        assert_eq(forwarded.closes(), 0)
      }
      let url = if secure {
        "https://example.test/chat"
      } else {
        "http://example.test/chat"
      }
      let response = h.client.send(upgrade_request(url~), exchange())
      let (taken, bytes) = response.attributes
        .get(@rt.upgraded)
        .unwrap()
        .take_conn()
        .unwrap()
      assert_eq(bytes, b"\x81\x00")
      assert_eq(h.dialer.dialed.length(), if secure { 1 } else { 2 })
      assert_true(h.dialer.dialed.all(dial => dial == ("proxy.test", 3128)))
      assert_eq(h.dialer.tls_hosts, if secure { ["example.test"] } else { [] })
      let written = conn.written().map(bytes => @utf8.decode(bytes)).join("")
      assert_true(
        written.has_prefix(
          if secure {
            "CONNECT example.test:443 HTTP/1.1"
          } else {
            "CONNECT example.test:80 HTTP/1.1"
          },
        ),
      )
      assert_true(written.contains("GET /chat HTTP/1.1"))
      taken.close()
      response.close()
      if forwarded is Some(forwarded) {
        assert_eq(forwarded.closes(), 1)
        let declined = h.scripted([
          Chunk(b"HTTP/1.1 200 Connection Established\r\n\r\n"),
          Chunk(ok("")),
        ])
        let response = h.client.send(upgrade_request(url~), exchange())
        assert_eq(response.status, 200)
        response.close()
        assert_eq(declined.closes(), 1)
        assert_eq(h.client.idle_connections(), 0)
        let normal = h.scripted([Chunk(ok(""))])
        h.client.send(@mttp_core.Request::get(url), exchange()).close()
        assert_true(
          @utf8.decode(normal.written()[0]).has_prefix(
            "GET http://example.test/chat HTTP/1.1",
          ),
        )
      }
      h.finish()
    })
  }
}

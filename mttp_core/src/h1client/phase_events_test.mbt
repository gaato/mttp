///|
/// `request` with an `on_phase` callback that records into `seen`.
fn observed(
  request : @mttp_core.Request,
  seen : Array[@mttp_core.PhaseEvent],
) -> @mttp_core.Request {
  {
    ..request,
    attributes: request.attributes.put(@mttp_core.on_phase, event => {
      seen.push(event)
    }),
  }
}

///|
test "phase events arrive in order, once each, and a reused connection reports Pooled(reused=true)" {
  let h = Harness::new()
  let peer = h.peer()
  let first = []
  let second = []
  h.run(() => {
    let server = h.driver.spawn(() => {
      assert_eq(peer.serve(ok("pong")).length(), 2)
    })
    let request = @mttp_core.Request::get("https://example.test/ping")
    assert_eq(fetch(h.client, observed(request, first)), "pong")
    assert_eq(fetch(h.client, observed(request, second)), "pong")
    h.finish()
    ignore(server.wait())
  })
  assert_eq(first, [
    Dialed(addr="example.test:443"),
    TlsDone,
    Pooled(reused=false),
    Written,
    FirstByte,
  ])
  assert_eq(second, [Pooled(reused=true), Written, FirstByte])
}

///|
test "a streamed upload reports Written after its last piece, and an IPv6 address is bracketed" {
  let h = Harness::new()
  let peer = h.peer()
  let seen = []
  h.run(() => {
    let server = h.driver.spawn(() => {
      assert_eq(peer.serve(ok("done")).length(), 1)
    })
    let source = @sim.Feed::bytes(h.driver, [b"a", b"b"])
    let request = @mttp_core.Request::post("http://[::1]:8080/upload").body_stream(
      source,
    )
    assert_eq(fetch(h.client, observed(request, seen)), "done")
    h.finish()
    ignore(server.wait())
  })
  assert_eq(seen, [
    Dialed(addr="[::1]:8080"),
    Pooled(reused=false),
    Written,
    FirstByte,
  ])
}

///|
test "through a TLS proxy's tunnel, Dialed names the proxy and TlsDone is reported once" {
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    proxy: @h1client.ProxyConfig::fixed("https://proxy.test:8443"),
  })
  ignore(
    h.scripted([
      Chunk(b"HTTP/1.1 200 Connection Established\r\n\r\n"),
      Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\ninside"),
    ]),
  )
  let seen = []
  h.run(() => {
    let request = @mttp_core.Request::get("https://origin.test/")
    assert_eq(fetch(h.client, observed(request, seen)), "inside")
    h.finish()
  })
  assert_eq(h.dialer.tls_hosts, ["proxy.test", "origin.test"])
  assert_eq(seen, [
    Dialed(addr="proxy.test:8443"),
    TlsDone,
    Pooled(reused=false),
    Written,
    FirstByte,
  ])
}

///|
test "a failed dial reports Dialed only once it connected, and nothing after the send raised" {
  let h = Harness::new()
  let seen = []
  h.run(() => {
    let (kind, phase) = failing(() => {
      ignore(
        h.client.send(
          observed(@mttp_core.Request::get("http://example.test/"), seen),
          exchange(),
        ),
      )
    })
    assert_eq(kind, Connect)
    assert_eq(phase, Dial)
    h.finish()
  })
  assert_eq(seen, [])
}

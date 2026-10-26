///|
test "portable backend preserves framing errors limits and body cleanup" {
  for
    (wire, expected) in [
      (
        b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n", "protocol",
      ),
      (
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 2\r\n\r\n",
        "protocol",
      ),
      (b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nx", "protocol"),
      (b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nabcdef", "limit"),
    ] {
    let driver = @driver.Driver::new()
    let coordination = @sim.SimCoordination::new(driver)
    let conn = @sim.ScriptedConn::new([Chunk(wire), Eof])
    let backend = @client.H1Backend::new(
      dialer=@sim.ScriptedDialer::new([conn]),
      coordination~,
      clock=@fake.SimClock::new(driver),
      timer=@fake.SimTimer::new(driver),
      max_body_bytes=5,
    )
    driver.run(() => {
      let actual = try {
        let response = backend.send(
          @model.Request::get("http://example/"),
          @httpclient.RequestOptions::default(),
        )
        defer response.close()
        ignore(@httpclient.read_body(response.body, 100))
        "accepted"
      } catch {
        @model.TransportError(kind=Protocol, ..) => "protocol"
        @model.TransportError(kind=TooLarge(..), ..) => "limit"
        error => raise error
      }
      assert_eq(actual, expected)
      assert_eq(backend.idle_connections(), 0)
      backend.close()
    })
    assert_eq(conn.closes(), 1)
  }
}

///|
test "head timeout and cancelled pool wait release every owned resource" {
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
  let blocked = @sim.ScriptedConn::new([Wait(coordination.signal())])
  let first = @sim.ScriptedConn::new([
    Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx"),
  ])
  let second = @sim.ScriptedConn::new([
    Chunk(b"HTTP/1.1 204 No Content\r\n\r\n"),
  ])
  let dialer = @sim.ScriptedDialer::new([blocked, first, second])
  let backend = @client.H1Backend::new(
    dialer~,
    coordination~,
    max_connections=1,
    read_timeout_ms=5,
    clock=@fake.SimClock::new(driver),
    timer=@fake.SimTimer::new(driver),
  )
  driver.run(() => {
    let timeout = try {
      ignore(
        backend.send(
          @model.Request::post("http://example/").body_bytes(b"x"),
          @httpclient.RequestOptions::default(),
        ),
      )
      false
    } catch {
      @model.TransportError(kind=Timeout(ms=5), phase=Head, ..) => true
      _ => false
    }
    assert_true(timeout)
    assert_eq(blocked.closes(), 1)
    let response = backend.send(
      @model.Request::get("http://example/"),
      @httpclient.RequestOptions::default(),
    )
    let queued = driver.spawn(() => {
      let reply = backend.send(
        @model.Request::get("http://example/"),
        @httpclient.RequestOptions::default(),
      )
      reply.close()
    })
    driver.sleep(1)
    assert_eq(dialer.dialed().length(), 2)
    queued.cancel()
    assert_false(queued.wait())
    response.close()
    let reply = backend.send(
      @model.Request::get("http://example/"),
      @httpclient.RequestOptions::default(),
    )
    assert_eq(reply.status, 204)
    reply.close()
    backend.close()
  })
  assert_eq(first.closes(), 1)
  assert_eq(second.closes(), 1)
}

///|
test "CONNECT and TLS are explicit dialer events" {
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
  let conn = @sim.ScriptedConn::new([
    Chunk(b"HTTP/1.1 200 Connection Established\r\n\r\n"),
    Chunk(b"HTTP/1.1 204 No Content\r\n\r\n"),
  ])
  let dialer = @sim.ScriptedDialer::new([conn])
  let backend = @client.H1Backend::new(
    dialer~,
    coordination~,
    proxy="https://proxy.test:8443",
    clock=@fake.SimClock::new(driver),
    timer=@fake.SimTimer::new(driver),
  )
  driver.run(() => {
    let response = backend.send(
      @model.Request::get("https://origin.test/"),
      @httpclient.RequestOptions::default(),
    )
    response.close()
    backend.close()
  })
  assert_eq(dialer.dialed(), [("proxy.test", 8443)])
  assert_eq(dialer.tls_hosts(), ["proxy.test", "origin.test"])
  assert_true(conn.written()[0].has_prefix(b"CONNECT origin.test:443 HTTP/1.1"))
  assert_eq(conn.closes(), 1)
}

///|
test "portable backend shares invalid request and close contracts" {
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
  driver.run(() => {
    let failures = @testing.check_backend_contract(() => {
      @client.H1Backend::new(
        dialer=@sim.ScriptedDialer::new([]),
        coordination~,
        clock=@fake.SimClock::new(driver),
        timer=@fake.SimTimer::new(driver),
      )
    })
    assert_eq(failures, [])
  })
}

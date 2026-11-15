///|
test "ping is due at its interval and any byte renews life before a complete frame" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = @sim.pair(@sim.SimCoordination::new(d), chunk_bytes=1)
    let s = session(d, conn, limits={
      ..limits(),
      ping_interval_ms: Some(3),
      pong_timeout_ms: Some(2),
    })
    d.run(() => {
      let receiver = d.spawn(() => assert_eq(s.recv(), @ws.Message::Text("x")))
      assert_true(read_packet(peer).0.opcode is Ping)
      assert_eq(d.now(), 3L)
      d.sleep(1)
      peer.write(b"\x81") // A head byte, with no complete frame yet, counts as life.
      assert_true(read_packet(peer).0.opcode is Ping)
      assert_eq(d.now(), 7L)
      d.sleep(1)
      peer.write(b"\x01x")
      ignore(receiver.wait())
      assert_eq(d.now(), 8L)
      s.abort()
      peer.close()
    })
    assert_eq(
      (conn.closes(), peer.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  })
}

///|
test "a zombie expires exactly at the answer deadline and closes once" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = @sim.pair(@sim.SimCoordination::new(d))
    let s = session(d, conn, limits={
      ..limits(),
      ping_interval_ms: Some(3),
      pong_timeout_ms: Some(2),
    })
    assert_true(recv_error(d, s) is @ws.WsError(kind=Timeout(ms=2), ..))
    assert_eq(d.now(), 5L)
    s.abort()
    peer.close()
    assert_eq(
      (conn.closes(), peer.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  })
}

///|
test "a session pair answers keepalive Pings under virtual time without leaking monitors" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (a, b) = @sim.pair(@sim.SimCoordination::new(d), chunk_bytes=1)
    let l = { ..limits(), ping_interval_ms: Some(3), pong_timeout_ms: Some(2), }
    let client = session(d, a, limits=l)
    let server = session(d, b, role=Server, limits=l)
    d.run(() => {
      let server_reader = d.spawn(() => {
        let _ = server.recv()
      })
      let writer = d.spawn(() => {
        d.sleep(10)
        server.send(Text("alive"))
      })
      assert_eq(client.recv(), @ws.Message::Text("alive"))
      ignore(writer.wait())
      server_reader.cancel()
      ignore(server_reader.wait())
      assert_eq(d.now(), 10L)
      client.abort()
      server.abort()
    })
    assert_eq(
      (a.closes(), b.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  })
}

///|
test "unset or nonpositive keepalive options disable both ping and zombie timers" {
  for
    (interval, answer) in [
      (None, Some(2)),
      (Some(3), None),
      (Some(0), Some(2)),
      (Some(3), Some(0)),
      (Some(-1), Some(2)),
    ] {
    let d = @driver.Driver::new()
    let (conn, peer) = controlled(d)
    conn.stalled = false
    let s = session(d, conn, limits={
      ..limits(),
      ping_interval_ms: interval,
      pong_timeout_ms: answer,
    })
    d.run(() => {
      let writer = d.spawn(() => {
        d.sleep(100)
        peer.write(packet(Text, b"late"))
      })
      assert_eq(s.recv(), @ws.Message::Text("late"))
      ignore(writer.wait())
      assert_eq(conn.writes, [])
      s.abort()
      peer.close()
    })
    assert_eq(
      (d.now(), conn.inner.closes(), d.live_tasks(), d.pending_timers()),
      (100L, 1, 0, 0),
    )
  }
}

///|
test "keepalive Ping entropy failure fails closed before any frame is written" {
  let d = @driver.Driver::new()
  let conn = @sim.ScriptedConn::new([
    Wait(@sim.SimCoordination::new(d).signal()),
  ])
  let s = session(d, conn, entropy=_ => None, limits={
    ..limits(),
    ping_interval_ms: Some(3),
    pong_timeout_ms: Some(2),
  })
  assert_true(recv_error(d, s) is @ws.WsError(kind=Protocol, ..))
  assert_eq(conn.written(), [])
  assert_eq(
    (d.now(), conn.closes(), d.live_tasks(), d.pending_timers()),
    (3L, 1, 0, 0),
  )
}

///|
test "answer deadline starts after a slow Ping write completes" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = controlled(d)
    let s = session(d, conn, limits={
      ..limits(),
      ping_interval_ms: Some(3),
      pong_timeout_ms: Some(2),
      send_timeout_ms: 10,
    })
    d.run(() => {
      let reader = d.spawn(() => {
        let expired = try {
          ignore(s.recv())
          false
        } catch {
          @ws.WsError(kind=Timeout(ms=2), ..) => true
          e => raise e
        }
        assert_true(expired)
      })
      conn.entered.wait()
      assert_eq(d.now(), 3L)
      d.sleep(4)
      conn.release.notify()
      assert_true(read_packet(peer).0.opcode is Ping)
      ignore(reader.wait())
      assert_eq(d.now(), 9L)
      peer.close()
    })
    assert_eq(
      (conn.inner.closes(), peer.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  })
}

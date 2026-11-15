///|
test "invalid fragment order mask RSV1 and Close codes fail with protocol Close" {
  let bad = [
    b"\x80\x00", b"\x01\x00\x81\x00", b"\x83\x00", b"\xc1\x00", b"\x89\x80abcd",
    b"\x88\x01x", b"\x88\x02\x03\xed",
  ]
  for wire in bad {
    let d = @driver.Driver::new()
    let conn = @sim.ScriptedConn::new([Chunk(wire)])
    let s = session(d, conn)
    assert_true(recv_error(d, s) is @ws.WsError(kind=Protocol, ..))
    assert_eq(reply_code(conn.written()), 1002)
    assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
  }
  let d = @driver.Driver::new()
  let ext = TestExtension::{
    encode_fn: b => (b, true),
    decode_fn: (b, _, _) => b,
  }
  let conn = @sim.ScriptedConn::new([Chunk(b"\x01\x00\xc0\x00")])
  assert_true(
    recv_error(d, session(d, conn, extension=ext))
    is @ws.WsError(kind=Protocol, ..),
  )
  assert_eq(reply_code(conn.written()), 1002)
}

///|
test "UTF8 is refused at the first invalid fragment byte and at an incomplete FIN" {
  for wire in [b"\x01\x01\xff", b"\x81\x01\xf0", b"\x88\x03\x03\xe8\xff"] {
    let d = @driver.Driver::new()
    let c = @sim.SimCoordination::new(d)
    let conn = @sim.ScriptedConn::new([Chunk(wire), Wait(c.signal())])
    let s = session(d, conn)
    assert_true(
      recv_error(d, s)
      is @ws.WsError(kind=Closed({ code: InvalidPayload, .. }), ..),
    )
    assert_eq(reply_code(conn.written()), 1007)
    assert_eq(
      (d.now(), conn.closes(), d.live_tasks(), d.pending_timers()),
      (0L, 1, 0, 0),
    )
  }
}

///|
test "Close handling ignores subsequent data and sends one reply" {
  let d = @driver.Driver::new()
  let wire = packet(Binary, b"", fin=false).repeat(4) +
    packet(Ping, b"ignored") +
    packet(Close, b"\x03\xe8") +
    packet(Text, b"late")
  let conn = @sim.ScriptedConn::new([Chunk(wire)])
  let s = session(d, conn, limits={ ..limits(), max_empty_frames: 0, })
  d.run(() => s.close({ code: Normal, reason: "", }))
  assert_eq(reply_code(conn.written()), 1000)
  assert_true(
    recv_error(d, s) is @ws.WsError(kind=Closed({ code: Normal, .. }), ..),
  )
  assert_eq(
    (d.now(), conn.closes(), d.live_tasks(), d.pending_timers()),
    (0L, 1, 0, 0),
  )
}

///|
test "close deadline accepts the peer before the bound and aborts at and beyond it" {
  for delay in [4, 5, 6] {
    let d = @driver.Driver::new()
    let c = @sim.SimCoordination::new(d)
    let release = c.signal()
    let conn = @sim.ScriptedConn::new([
      Wait(release),
      Chunk(packet(Close, b"\x03\xe8")),
    ])
    let s = session(d, conn, limits={ ..limits(), close_timeout_ms: 5, })
    d.run(() => {
      let _ = d.add_timer(delay.to_int64(), () => release.notify())
      s.close({ code: Normal, reason: "", })
    })
    let expected = if delay < 5 { 1000 } else { 1006 }
    guard recv_error(d, s) is @ws.WsError(kind=Closed(frame), ..) else {
      fail("missing close status")
    }
    assert_eq(frame.code.to_int(), expected)
    assert_eq(conn.written().length(), 1)
    assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
  }
}

///|
test "client masks every frame with fresh entropy and server never asks for it" {
  let d = @driver.Driver::new()
  let requests = []
  let conn = @sim.ScriptedConn::new([
    Chunk(
      packet(Ping, b"ping") +
      packet(Text, b"reply") +
      packet(Close, b"\x03\xe8"),
    ),
  ])
  let s = session(d, conn, entropy=n => {
    requests.push(n)
    Some(Bytes::make(n, requests.length().to_byte()))
  })
  d.run(() => {
    s.send(Text("one"))
    s.send(Binary(b"two"))
    assert_eq(s.recv(), @ws.Message::Text("reply"))
    s.close({ code: Normal, reason: "", })
  })
  assert_eq(requests, [4, 4, 4, 4])
  for i, bytes in conn.written() {
    assert_eq(bytes[2:6].to_owned(), Bytes::make(4, (i + 1).to_byte()))
  }
  let d = @driver.Driver::new()
  let conn = @sim.ScriptedConn::new([])
  let s = session(d, conn, role=Server, entropy=n => {
    requests.push(n)
    None
  })
  d.run(() => {
    s.send(Binary(b"x"))
    s.abort()
  })
  assert_eq(conn.written(), [b"\x82\x01x"])
  assert_eq(requests.length(), 4)
}

///|
test "entropy failure or wrong length refuses all bytes without fallback" {
  for key in [None, Some(b"abc"), Some(b"abcde")] {
    let d = @driver.Driver::new()
    let conn = @sim.ScriptedConn::new([])
    let s = session(d, conn, entropy=_ => key)
    let rejected = d.run(() => {
      try {
        s.send(Text("x"))
        false
      } catch {
        @ws.WsError(kind=Protocol, ..) => true
        e => raise e
      }
    })
    assert_true(rejected)
    assert_eq(conn.written(), [])
    assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
  }
}

///|
test "raw text and binary send sizes count bytes and admit only the exact message bound" {
  for
    message in [
      @ws.Message::Text("aé"),
      Text("aéb"),
      Binary(b"abc"),
      Binary(b"abcd"),
    ] {
    let d = @driver.Driver::new()
    let conn = @sim.ScriptedConn::new([])
    let s = session(d, conn, limits={ ..limits(), max_message_bytes: 3, })
    d.run(() => {
      let rejected = try {
        s.send(message)
        false
      } catch {
        @ws.WsError(kind=TooLarge(limit=3), ..) => true
        e => raise e
      }
      assert_eq(rejected, message is Text("aéb") || message is Binary(b"abcd"))
      s.abort()
    })
    assert_eq((conn.closes(), d.live_tasks()), (1, 0))
  }
}

///|
test "invalid local Close aborts without writing and a failed Close write is noraise" {
  for
    frame in [
      @ws.CloseFrame::{ code: Other(1004), reason: "", },
      { code: Normal, reason: "x".repeat(124), },
    ] {
    let d = @driver.Driver::new()
    let conn = @sim.ScriptedConn::new([])
    let s = session(d, conn)
    d.run(() => s.close(frame))
    assert_eq(conn.written(), [])
    assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
  }
  let d = @driver.Driver::new()
  let cause = @mttp_core.TransportError(
    kind=Network,
    phase=Write,
    detail="Close write failed",
  )
  let conn = @sim.ScriptedConn::new([], write_error=cause)
  d.run(() => session(d, conn).close({ code: Normal, reason: "", }))
  assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
}

///|
test "failed Pong writes fail the session and a failed error Close keeps the first cause" {
  for protocol_error in [false, true] {
    let d = @driver.Driver::new()
    let cause = @mttp_core.TransportError(
      kind=Network,
      phase=Write,
      detail="control write failed",
    )
    let wire = if protocol_error {
      b"\x80\x00"
    } else {
      packet(Ping, b"x") + packet(Text, b"x")
    }
    let conn = @sim.ScriptedConn::new([Chunk(wire)], write_error=cause)
    let error = recv_error(d, session(d, conn))
    if protocol_error {
      assert_true(error is @ws.WsError(kind=Protocol, ..))
    } else {
      assert_true(error is @ws.WsError(kind=Transport(_), ..))
    }
    assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
  }
}

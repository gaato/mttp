///|
fn recv_error(d : @driver.Driver, s : &@ws.Session) -> @ws.WsError raise {
  d.run(() => {
    try {
      let _ = s.recv()
      fail("expected recv failure")
    } catch {
      @ws.WsError(_) as e => e
      error => raise error
    }
  })
}

///|
fn reply_code(writes : Array[Bytes]) -> Int32 raise {
  assert_eq(writes.length(), 1)
  let parser = @frame.Parser::new(
    role=Server,
    max_frame_bytes=125,
    allow_rsv1=false,
  )
  parser.feed(writes[0])
  assert_true(parser.next() is Some(Head({ opcode: Close, .. })))
  let payload = Buffer()
  for ;; {
    match parser.next() {
      Some(Payload(bytes)) => payload.write_bytes(bytes)
      Some(End) => break
      _ => fail("invalid Close reply")
    }
  }
  @ws.CloseFrame::parse(payload.to_bytes()).code.to_int()
}

///|
test "limits default to the agreed byte time keepalive and empty frame bounds" {
  let l = @ws.WsLimits::default()
  assert_eq(
    (l.max_frame_bytes, l.max_message_bytes, l.max_empty_frames),
    (16777216, 16777216, 1024),
  )
  assert_eq(
    (
      l.send_timeout_ms,
      l.close_timeout_ms,
      l.ping_interval_ms,
      l.pong_timeout_ms,
    ),
    (30000, 5000, Some(30000), Some(10000)),
  )
}

///|
test "Close code mapping reserved ranges and UTF8 reason bound are strict" {
  for n in -1..<65537 {
    let code = @ws.CloseCode::from_int(n)
    assert_eq(code.to_int(), n)
    let expected = (n >= 1000 && n <= 1003) ||
      (n >= 1007 && n <= 1014) ||
      (n >= 3000 && n <= 4999)
    assert_eq(code.sendable(), expected)
    if expected {
      let frame = @ws.CloseFrame::{ code, reason: "", }
      assert_eq(@ws.CloseFrame::parse(frame.encode()), frame)
    }
  }
  let exact = @ws.CloseFrame::{ code: Normal, reason: "é".repeat(61) + "a", }
  assert_eq(exact.encode().length(), 125)
  assert_eq(@ws.CloseFrame::parse(exact.encode()), exact)
  let overflow = @ws.CloseFrame::{ ..exact, reason: exact.reason + "b", }
  assert_true(
    try {
      ignore(overflow.encode())
      false
    } catch {
      @ws.WsError(kind=Protocol, ..) => true
      e => raise e
    },
  )
  for
    bytes in [
      b"x",
      Bytes::make(126, 0),
      b"\x03\xed",
      b"\x03\xec",
      b"\x03\xee",
      b"\x03\xf7",
    ] {
    assert_true(
      try {
        ignore(@ws.CloseFrame::parse(bytes))
        false
      } catch {
        @ws.WsError(kind=Protocol, ..) => true
        e => raise e
      },
    )
  }
  for bytes in [b"\x03\xe8\xff", b"\x03\xe8\xf0\x9f"] {
    assert_true(
      try {
        ignore(@ws.CloseFrame::parse(bytes))
        false
      } catch {
        @ws.WsError(kind=Closed({ code: InvalidPayload, .. }), ..) => true
        e => raise e
      },
    )
  }
  let empty = @ws.CloseFrame::{ code: NoStatus, reason: "", }
  assert_eq(empty.encode(), b"")
  assert_eq(@ws.CloseFrame::parse(b""), empty)
  for code in [@ws.CloseCode::Abnormal, Other(1015), Other(2999)] {
    assert_true(
      try {
        ignore(@ws.CloseFrame::{ code, reason: "", }.encode())
        false
      } catch {
        @ws.WsError(kind=Protocol, ..) => true
        e => raise e
      },
    )
  }
}

///|
test "frame and fragmented wire message bounds accept exact and reject plus one" {
  for size in [3, 4] {
    let d = @driver.Driver::new()
    let conn = @sim.ScriptedConn::new([
      Chunk(packet(Binary, Bytes::make(size, 1))),
    ])
    let s = session(d, conn, limits={ ..limits(), max_frame_bytes: 3, })
    if size == 3 {
      d.run(() => {
        assert_eq(s.recv(), @ws.Message::Binary(Bytes::make(3, 1)))
        s.abort()
      })
    } else {
      assert_true(recv_error(d, s) is @ws.WsError(kind=TooLarge(limit=3), ..))
      assert_eq(reply_code(conn.written()), 1009)
    }
    assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
  }
  for size in [1, 2] {
    let d = @driver.Driver::new()
    let wire = packet(Binary, b"ab", fin=false) +
      packet(Continuation, Bytes::make(size, 3))
    let conn = @sim.ScriptedConn::new([Chunk(wire)])
    let s = session(d, conn, limits={ ..limits(), max_message_bytes: 3, })
    if size == 1 {
      d.run(() => {
        assert_eq(s.recv(), @ws.Message::Binary(b"ab\x03"))
        s.abort()
      })
    } else {
      assert_true(recv_error(d, s) is @ws.WsError(kind=TooLarge(limit=3), ..))
      assert_eq(reply_code(conn.written()), 1009)
    }
    assert_eq((conn.closes(), d.live_tasks()), (1, 0))
  }
}

///|
test "empty frame bound admits 1024 refuses 1025 and nonempty frames reset it" {
  for n in [1024, 1025] {
    let d = @driver.Driver::new()
    let conn = @sim.ScriptedConn::new([
      Chunk(b"\x8a\x00".repeat(n) + packet(Text, b"x")),
    ])
    let s = session(d, conn)
    if n == 1024 {
      d.run(() => {
        assert_eq(s.recv(), @ws.Message::Text("x"))
        s.abort()
      })
    } else {
      assert_true(recv_error(d, s) is @ws.WsError(kind=Protocol, ..))
      assert_eq(reply_code(conn.written()), 1002)
    }
    assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
  }
  let d = @driver.Driver::new()
  let conn = @sim.ScriptedConn::new([
    Chunk(b"\x8a\x00\x8a\x01x\x8a\x00\x81\x01x"),
  ])
  let s = session(d, conn, limits={ ..limits(), max_empty_frames: 1, })
  d.run(() => {
    assert_eq(s.recv(), @ws.Message::Text("x"))
    s.abort()
  })
}

///|
test "control payload accepts 125 and rejects 126 with protocol Close" {
  for n in [125, 126] {
    let d = @driver.Driver::new()
    let wire = if n == 125 {
      packet(Ping, Bytes::make(n, 7))
    } else {
      b"\x89\x7e\x00\x7e" + Bytes::make(n, 7)
    }
    let conn = @sim.ScriptedConn::new([Chunk(wire + packet(Text, b"x"))])
    let s = session(d, conn)
    if n == 125 {
      d.run(() => {
        assert_eq(s.recv(), @ws.Message::Text("x"))
        s.abort()
      })
      let p = @frame.Parser::new(
        role=Server,
        max_frame_bytes=125,
        allow_rsv1=false,
      )
      p.feed(conn.written()[0])
      assert_true(p.next() is Some(Head({ opcode: Pong, length: 125L, .. })))
      assert_eq(p.next(), Some(@frame.Event::Payload(Bytes::make(125, 7))))
    } else {
      assert_true(recv_error(d, s) is @ws.WsError(kind=Protocol, ..))
      assert_eq(reply_code(conn.written()), 1002)
    }
    assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
  }
}

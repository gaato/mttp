///|
fn limits() -> @ws.WsLimits {
  { ..@ws.WsLimits::default(), ping_interval_ms: None, pong_timeout_ms: None, }
}

///|
fn session(
  d : @driver.Driver,
  conn : &@rt.Conn,
  role~ : @frame.Role = Client,
  pending~ : Bytes = b"",
  limits~ : @ws.WsLimits = limits(),
  entropy~ : (Int32) -> Bytes? = _ => Some(b"abcd"),
  extension? : &@ws.Extension,
) -> &@ws.Session {
  @ws.session_over_conn(
    conn,
    role~,
    pending~,
    clock=@sim.SimClock::new(d),
    timer=@sim.SimTimer::new(d),
    coordination=@sim.SimCoordination::new(d),
    entropy~,
    limits~,
    extension?,
    subprotocol="test",
  )
}

///|
fn closed(frame : @ws.CloseFrame) -> Bool {
  frame.code.to_int() == 1000
}

///|
test "session pair exchanges text binary and closes from either side without leaks" {
  @sim.explore(schedule => {
    for initiator in 0..<2 {
      let d = @driver.Driver::new(schedule~)
      let c = @sim.SimCoordination::new(d)
      let (a, b) = @sim.pair(c, chunk_bytes=1)
      let left = session(d, a)
      let right = session(d, b, role=Server)
      assert_eq(left.subprotocol(), Some("test"))
      d.run(() => {
        left.send(Text("hello🙂"))
        assert_eq(right.recv(), @ws.Message::Text("hello🙂"))
        right.send(Binary(b"\x00\xff"))
        assert_eq(left.recv(), @ws.Message::Binary(b"\x00\xff"))
        let (sender, receiver) = if initiator == 0 {
          (left, right)
        } else {
          (right, left)
        }
        let reader = d.spawn(() => {
          let _ = receiver.recv() catch {
            @ws.WsError(kind=Closed(frame), ..) => {
              assert_true(closed(frame))
              return
            }
            e => raise e
          }
          fail("expected Close")
        })
        sender.close({ code: Normal, reason: "done", })
        ignore(reader.wait())
        sender.close({ code: GoingAway, reason: "again", })
        sender.abort()
        receiver.abort()
      })
      assert_eq(
        (a.closes(), b.closes(), d.live_tasks(), d.pending_timers()),
        (1, 1, 0, 0),
      )
    }
  })
}

///|
test "fragmented text validates across frames and interleaved Ping replies with latest Pong" {
  let d = @driver.Driver::new()
  let conn = @sim.ScriptedConn::new([
    Chunk(b"\x01\x02\xf0\x9f\x89\x01a\x89\x01b\x80\x02\x99\x82"),
  ])
  let s = session(d, conn)
  d.run(() => {
    assert_eq(s.recv(), @ws.Message::Text("🙂"))
    s.abort()
  })
  assert_eq(conn.written(), [b"\x8a\x81abcd\x03"])
  assert_eq((conn.closes(), d.live_tasks()), (1, 0))
}

///|
test "simultaneous close sends one Close and Closed is permanent" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (a, b) = @sim.pair(@sim.SimCoordination::new(d))
    let left = session(d, a)
    let right = session(d, b, role=Server)
    d.run(() => {
      let l = d.spawn(() => left.close({ code: Normal, reason: "", }))
      let r = d.spawn(() => right.close({ code: GoingAway, reason: "", }))
      ignore(l.wait())
      ignore(r.wait())
      left.send(Text("late")) catch {
        @ws.WsError(kind=Closed(_), ..) => ()
        e => raise e
      }
      left.abort()
      right.abort()
    })
    assert_eq(
      (a.closes(), b.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  })
}

///|
test "close wait expires at its bound and abort is immediate" {
  for ms in [0, 5, 6] {
    let d = @driver.Driver::new()
    let c = @sim.SimCoordination::new(d)
    let conn = @sim.ScriptedConn::new([Wait(c.signal())])
    let s = session(d, conn, limits={ ..limits(), close_timeout_ms: ms, })
    d.run(() => s.close({ code: Normal, reason: "", }))
    assert_eq(d.now(), ms.to_int64())
    assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
  }
  let d = @driver.Driver::new()
  let conn = @sim.ScriptedConn::new([])
  let s = session(d, conn)
  s.abort()
  s.abort()
  d.run(() => {
    let _ = s.recv() catch {
      @ws.WsError(kind=Closed({ code: Abnormal, .. }), ..) => return
      e => raise e
    }
    fail("expected abort")
  })
  assert_eq(conn.closes(), 1)
  assert_eq(conn.written(), [])
}

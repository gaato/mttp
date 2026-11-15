///|
/// Suspends its first write after a real one-byte prefix. Close wakes the
/// blocked write, so deadlines exercise transport cleanup as well as timers.
priv struct ControlledConn {
  inner : @sim.SimConn
  entered : &@rt.Signal
  release : &@rt.Signal
  writes : Array[Bytes]
  mut stalled : Bool
}

///|
fn controlled(d : @driver.Driver) -> (ControlledConn, @sim.SimConn) {
  let c = @sim.SimCoordination::new(d)
  let (inner, peer) = @sim.pair(c)
  (
    {
      inner,
      entered: c.signal(),
      release: c.signal(),
      writes: [],
      stalled: true,
    },
    peer,
  )
}

///|
impl @rt.Conn for ControlledConn with fn read(self, max_len~) {
  self.inner.read(max_len~)
}

///|
impl @rt.Conn for ControlledConn with fn write(self, bytes) {
  self.writes.push(bytes)
  if self.stalled {
    self.stalled = false
    self.inner.write(bytes[:1].to_owned())
    self.entered.notify()
    self.release.wait()
    self.inner.write(bytes[1:].to_owned())
  } else {
    self.inner.write(bytes)
  }
}

///|
impl @rt.Conn for ControlledConn with fn close(self) {
  self.inner.close()
  self.release.notify()
}

///|
fn packet(
  opcode : @frame.Opcode,
  payload : Bytes,
  fin~ : Bool = true,
  rsv1~ : Bool = false,
  masked~ : Bool = false,
) -> Bytes raise {
  let key = if masked { Some(b"abcd") } else { None }
  let head = @frame.encode_head(
    @frame.FrameHead::new(
      fin~,
      rsv1~,
      opcode~,
      masked~,
      length=payload.length().to_int64(),
    ),
    mask?=key,
  )
  let body = if masked { @frame.apply_mask(payload, b"abcd") } else { payload }
  head + body
}

///|
async fn read_packet(
  peer : &@rt.Conn,
  role~ : @frame.Role = Server,
) -> (@frame.FrameHead, Bytes) {
  let p = @frame.Parser::new(role~, max_frame_bytes=16777216, allow_rsv1=true)
  let mut head : @frame.FrameHead? = None
  let out = Buffer()
  for ;; {
    match p.next() {
      Some(Head(h)) => head = Some(h)
      Some(Payload(bytes)) => out.write_bytes(bytes)
      Some(End) => {
        guard head is Some(h) else { fail("missing frame head") }
        return (h, out.to_bytes())
      }
      None => {
        guard peer.read(max_len=1) is Some(bytes) else {
          fail("EOF inside frame")
        }
        p.feed(bytes)
      }
    }
  }
}

///|
test "cancelled recv during partial Pong write must remain retryable" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = controlled(d)
    let s = session(d, conn)
    d.run(() => {
      peer.write(packet(Ping, b"x"))
      let reader = d.spawn(() => {
        let _ = s.recv()
      })
      conn.entered.wait()
      reader.cancel()
      d.pause()
      assert_false(reader.is_finished())
      assert_eq(conn.inner.closes(), 0)
      conn.release.notify()
      ignore(reader.wait())
      assert_true(reader.is_cancelled())
      assert_eq(read_packet(peer).1, b"x")
      peer.write(packet(Text, b"retained"))
      assert_eq(s.recv(), @ws.Message::Text("retained"))
      s.abort()
      peer.close()
    })
    assert_eq(
      (conn.inner.closes(), peer.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  })
}

///|
test "a protected Pong deadline closes a blocked transport and joins cancelled recv" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = controlled(d)
    let s = session(d, conn, limits={ ..limits(), send_timeout_ms: 5, })
    d.run(() => {
      peer.write(packet(Ping, b"x"))
      let reader = d.spawn(() => {
        let _ = s.recv()
      })
      conn.entered.wait()
      reader.cancel()
      ignore(reader.wait())
      assert_eq(d.now(), 5L)
      assert_eq(conn.inner.closes(), 1)
      peer.close()
    })
    assert_eq((d.live_tasks(), d.pending_timers()), (0, 0))
  })
}

///|
test "a cancelled data send mid frame fails the session and closes its transport" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = controlled(d)
    let s = session(d, conn)
    d.run(() => {
      let sending = d.spawn(() => s.send(Text("partial")))
      conn.entered.wait()
      sending.cancel()
      ignore(sending.wait())
      assert_true(sending.is_cancelled())
      assert_eq(conn.inner.closes(), 1)
      let rejected = try {
        s.send(Text("late"))
        false
      } catch {
        @ws.WsError(kind=Closed(_), ..) => true
        e => raise e
      }
      assert_true(rejected)
      peer.close()
    })
    assert_eq((d.live_tasks(), d.pending_timers()), (0, 0))
  })
}

///|
test "a read racing the keepalive deadline preserves the first delivered outcome" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = @sim.pair(@sim.SimCoordination::new(d))
    let s = session(d, conn, limits={
      ..limits(),
      ping_interval_ms: Some(3),
      pong_timeout_ms: Some(2),
    })
    let outcome = Ref(0)
    d.run(() => {
      let reader = d.spawn(() => {
        try {
          assert_eq(s.recv(), @ws.Message::Text("x"))
          outcome.val = 1
        } catch {
          @ws.WsError(kind=Timeout(ms=2), ..) => outcome.val = 2
          e => raise e
        }
      })
      assert_true(read_packet(peer).0.opcode is Ping)
      let writer = d.spawn(() => {
        d.sleep(2)
        peer.write(packet(Text, b"x")) catch {
          _ => ()
        }
      })
      ignore(reader.wait())
      ignore(writer.wait())
      assert_true(outcome.val == 1 || outcome.val == 2)
      s.abort()
      peer.close()
    })
    assert_eq(
      (
        d.now(),
        conn.closes(),
        peer.closes(),
        d.live_tasks(),
        d.pending_timers(),
      ),
      (5L, 1, 1, 0, 0),
    )
  })
}

///|
test "peer vanishing mid frame is abnormal closure and disposes of the connection" {
  let d = @driver.Driver::new()
  let conn = @sim.ScriptedConn::new([Chunk(b"\x82\x03a"), Eof])
  let s = session(d, conn)
  assert_true(
    recv_error(d, s) is @ws.WsError(kind=Closed({ code: Abnormal, .. }), ..),
  )
  assert_eq(conn.written(), [])
  assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
}

///|
test "read transport failure mid frame keeps its cause and closes" {
  let d = @driver.Driver::new()
  let cause = @mttp_core.TransportError(
    kind=Network,
    phase=Unknown,
    detail="read failed",
  )
  let conn = @sim.ScriptedConn::new([Chunk(b"\x82\x03a"), Failure(cause)])
  let s = session(d, conn)
  guard recv_error(d, s) is @ws.WsError(kind=Transport(actual), ..) else {
    fail("lost transport cause")
  }
  let @mttp_core.TransportError(detail~, ..) = actual
  assert_eq(detail, "read failed")
  assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
}

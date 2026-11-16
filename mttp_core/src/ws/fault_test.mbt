///|
/// One bounded transport chunk per direction. Partial reads keep the slot
/// occupied, so a Pong must wait until the peer drains the preceding input.
priv struct PressureSlot {
  mut remaining : Int32
  mut closed : Bool
  mut changed : &@rt.Signal
  coordination : &@rt.Coordination
}

///|
fn PressureSlot::wake(self : PressureSlot) -> Unit {
  let changed = self.changed
  self.changed = self.coordination.signal()
  changed.notify()
}

///|
priv struct PressureConn {
  inner : @sim.SimConn
  input : PressureSlot
  output : PressureSlot
  piece_bytes : Int32
}

///|
impl @rt.Conn for PressureConn with fn read(self, max_len~) {
  let bytes = self.inner.read(max_len=max_len.min(1))
  if bytes is Some(bytes) {
    self.input.remaining -= bytes.length()
    self.input.wake()
  }
  bytes
}

///|
impl @rt.Conn for PressureConn with fn write(self, bytes) {
  for offset = 0; offset < bytes.length(); {
    while self.output.remaining > 0 && !self.output.closed {
      self.output.changed.wait()
    }
    if self.output.closed {
      raise @mttp_core.TransportError(
        kind=Network,
        phase=Write,
        detail="closed pressure pipe",
      )
    }
    let end = offset + (bytes.length() - offset).min(self.piece_bytes)
    self.output.remaining = end - offset
    self.inner.write(bytes[offset:end].to_owned())
    continue end
  }
}

///|
impl @rt.Conn for PressureConn with fn close(self) {
  self.input.closed = true
  self.output.closed = true
  self.input.wake()
  self.output.wake()
  self.inner.close()
}

///|
test "two full backpressured pipes keep reading while both sessions reply to Ping" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let c = @sim.SimCoordination::new(d)
    let (a, b) = @sim.pair(c)
    let ab = PressureSlot::{
      remaining: 0,
      closed: false,
      changed: c.signal(),
      coordination: c,
    }
    let ba = PressureSlot::{
      remaining: 0,
      closed: false,
      changed: c.signal(),
      coordination: c,
    }
    let left_conn = PressureConn::{
      inner: a,
      input: ba,
      output: ab,
      piece_bytes: 64,
    }
    let right_conn = PressureConn::{
      inner: b,
      input: ab,
      output: ba,
      piece_bytes: 64,
    }
    let bounds = { ..limits(), send_timeout_ms: 5, }
    let left = session(d, left_conn, limits=bounds)
    let right = session(d, right_conn, role=Server, limits=bounds)
    d.run(() => {
      @rt.Conn::write(
        left_conn,
        packet(Ping, b"left", masked=true) + packet(Pong, b"fill", masked=true),
      )
      @rt.Conn::write(
        right_conn,
        packet(Ping, b"right") + packet(Pong, b"fill"),
      )
      assert_true(ab.remaining > 0 && ba.remaining > 0)
      let l = d.spawn(() => assert_eq(left.recv(), @ws.Message::Text("right")))
      let r = d.spawn(() => assert_eq(right.recv(), @ws.Message::Text("left")))
      // Let both control replies finish and their Pongs be read before
      // supplying the application messages that end these recv calls.
      d.sleep(6)
      assert_eq((a.closes(), b.closes()), (0, 0))
      assert_eq((ab.remaining, ba.remaining), (0, 0))
      let ls = d.spawn(() => left.send(Text("left")))
      let rs = d.spawn(() => right.send(Text("right")))
      ignore(l.wait())
      ignore(r.wait())
      ignore(ls.wait())
      ignore(rs.wait())
      assert_eq((a.closes(), b.closes(), d.now()), (0, 0, 6L))
      left.abort()
      right.abort()
    })
    assert_eq(
      (a.closes(), b.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  })
  // Also keep reading once both application messages are ready: each
  // control write below stalls after every byte, including a partial Pong.
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let c = @sim.SimCoordination::new(d)
    let (a, b) = @sim.pair(c)
    let ab = PressureSlot::{
      remaining: 0,
      closed: false,
      changed: c.signal(),
      coordination: c,
    }
    let ba = PressureSlot::{
      remaining: 0,
      closed: false,
      changed: c.signal(),
      coordination: c,
    }
    let left_conn = PressureConn::{
      inner: a,
      input: ba,
      output: ab,
      piece_bytes: 1,
    }
    let right_conn = PressureConn::{
      inner: b,
      input: ab,
      output: ba,
      piece_bytes: 1,
    }
    let bounds = { ..limits(), send_timeout_ms: 5, }
    let left = session(
      d,
      left_conn,
      pending=packet(Ping, b"right"),
      limits=bounds,
    )
    let right = session(
      d,
      right_conn,
      role=Server,
      pending=packet(Ping, b"left", masked=true),
      limits=bounds,
    )
    d.run(() => {
      let from_left = packet(Text, b"left", masked=true)
      let from_right = packet(Text, b"right")
      ab.remaining = from_left.length()
      ba.remaining = from_right.length()
      a.write(from_left)
      b.write(from_right)
      let l = d.spawn(() => assert_eq(left.recv(), @ws.Message::Text("right")))
      let r = d.spawn(() => assert_eq(right.recv(), @ws.Message::Text("left")))
      ignore(l.wait())
      ignore(r.wait())
      assert_eq((a.closes(), b.closes(), d.now()), (0, 0, 0L))
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
test "Pong read-ahead is bounded at 64 KiB and parsing resumes for the next byte" {
  @sim.explore(schedule => {
    // Four bytes of unmasked frame head: the first wire packet is exactly
    // 64 KiB, the second one byte larger. A blocked Pong is released only
    // by decoding the message, so unbounded read-ahead would deadlock.
    for size in [65532, 65533, 65536] {
      let d = @driver.Driver::new(schedule~)
      let (conn, peer) = controlled(d)
      let extension = TestExtension::{
        encode_fn: b => (b, false),
        decode_fn: (b, _, _) => {
          conn.release.notify()
          b
        },
      }
      let s = session(d, conn, extension~, limits={
        ..limits(),
        send_timeout_ms: 5,
      })
      d.run(() => {
        peer.write(packet(Ping, b"x"))
        let receiver = d.spawn(() => {
          assert_eq(s.recv(), @ws.Message::Binary(Bytes::make(size, b'x')))
        })
        conn.entered.wait()
        peer.write(packet(Binary, Bytes::make(size, b'x')))
        ignore(receiver.wait())
        assert_eq(d.now(), 0L)
        assert_eq(read_packet(peer).1, b"x")
        s.abort()
        peer.close()
      })
      assert_eq((d.live_tasks(), d.pending_timers()), (0, 0))
    }
  })
}

///|
/// Suspends its first write after a real one-byte prefix. Close wakes the
/// blocked write, so deadlines exercise transport cleanup as well as timers.
priv struct ControlledConn {
  inner : @sim.SimConn
  entered : &@rt.Signal
  release : &@rt.Signal
  writes : Array[Bytes]
  mut stalled : Bool
  mut on_read : (() -> Unit)?
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
      on_read: None,
    },
    peer,
  )
}

///|
impl @rt.Conn for ControlledConn with fn read(self, max_len~) {
  let bytes = self.inner.read(max_len~)
  if bytes is Some(_) && self.on_read is Some(hook) {
    self.on_read = None
    hook()
  }
  bytes
}

///|
priv struct PongReadFault {
  inner : ControlledConn
  failure : @mttp_core.TransportError?
  mut first : Bool
}

///|
impl @rt.Conn for PongReadFault with fn read(self, max_len~) {
  if self.first {
    self.first = false
    return @rt.Conn::read(self.inner, max_len~)
  }
  if self.failure is Some(failure) {
    raise failure
  }
  None
}

///|
impl @rt.Conn for PongReadFault with fn write(self, bytes) {
  @rt.Conn::write(self.inner, bytes)
}

///|
impl @rt.Conn for PongReadFault with fn close(self) {
  @rt.Conn::close(self.inner)
}

///|
test "Pong read-ahead joins EOF and preserves transport failures" {
  @sim.explore(schedule => {
    for
      failure in [
        None,
        Some(
          @mttp_core.TransportError(
            kind=Network,
            phase=Body,
            detail="read-ahead injection",
          ),
        ),
      ] {
      let d = @driver.Driver::new(schedule~)
      let (conn, peer) = controlled(d)
      let s = session(
        d,
        PongReadFault::{ inner: conn, failure, first: true, },
        limits={ ..limits(), send_timeout_ms: 5, },
      )
      d.run(() => {
        peer.write(packet(Ping, b"x"))
        let receiver = d.spawn(() => {
          let seen = try {
            ignore(s.recv())
            false
          } catch {
            @ws.WsError(kind=Transport(cause), ..) =>
              failure is Some(expected) && physical_equal(cause, expected)
            @ws.WsError(kind=Closed({ code: Abnormal, .. }), ..) =>
              failure is None
            e => raise e
          }
          assert_true(seen)
        })
        conn.entered.wait()
        let _ = d.add_timer(1L, () => conn.release.notify())
        ignore(receiver.wait())
        assert_eq(d.now(), 1L)
        s.abort()
        peer.close()
      })
      assert_eq(
        (conn.inner.closes(), peer.closes(), d.live_tasks(), d.pending_timers()),
        (1, 1, 0, 0),
      )
    }
  })
}

///|
test "completed messages return before the next partial header after a Pong" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = controlled(d)
    conn.stalled = false
    let next = packet(Binary, b"next")
    let s = session(
      d,
      conn,
      pending=packet(Ping, b"x") + packet(Text, b"ready") + next[:1].to_owned(),
    )
    d.run(() => {
      defer s.abort()
      defer peer.close()
      let received : Ref[@ws.Message?] = Ref(None)
      let receiver = d.spawn(() => received.val = Some(s.recv()))
      d.sleep(1)
      assert_eq(received.val, Some(@ws.Message::Text("ready")))
      assert_eq(conn.inner.closes(), 0)
      ignore(receiver.wait())
      peer.write(next[1:].to_owned())
      assert_eq(s.recv(), @ws.Message::Binary(b"next"))
      assert_eq(read_packet(peer).1, b"x")
    })
    assert_eq((d.live_tasks(), d.pending_timers()), (0, 0))
  })
}

///|
test "Pong read-ahead errors follow every already buffered message" {
  @sim.explore(schedule => {
    for role in [@frame.Role::Client, @frame.Role::Server] {
      for buffering in 0..<3 {
        let ahead = buffering == 2
        let d = @driver.Driver::new(schedule~)
        let (conn, peer) = controlled(d)
        let failure = @mttp_core.TransportError(
          kind=IncompleteClose,
          phase=Body,
          detail="speculative TLS read failed",
        )
        let masked = role is Server
        let second = packet(Binary, b"second", masked~)
        let head_len = second.length() - b"second".length()
        let prefix = packet(Ping, b"x", masked~) +
          packet(Text, b"first", masked~)
        let s = session(
          d,
          PongReadFault::{ inner: conn, failure: Some(failure), first: true, },
          role~,
          pending=if ahead {
            prefix + second[:head_len].to_owned()
          } else {
            b""
          },
        )
        d.run(() => {
          defer s.abort()
          defer peer.close()
          peer.write(
            if ahead {
              second[head_len:].to_owned() + packet(Text, b"third", masked~)
            } else if buffering == 0 {
              prefix
            } else {
              prefix + second
            },
          )
          let receiver = d.spawn(() => {
            assert_eq(s.recv(), @ws.Message::Text("first"))
            if buffering != 0 {
              assert_eq(s.recv(), @ws.Message::Binary(b"second"))
            }
            if ahead {
              assert_eq(s.recv(), @ws.Message::Text("third"))
            }
            let seen = try {
              ignore(s.recv())
              false
            } catch {
              @ws.WsError(kind=Transport(cause), ..) =>
                physical_equal(cause, failure)
              error => raise error
            }
            assert_true(seen)
          })
          conn.entered.wait()
          let _ = d.add_timer(1L, () => conn.release.notify())
          ignore(receiver.wait())
          assert_eq(d.now(), 1L)
        })
        assert_eq(
          (conn.inner.closes(), d.live_tasks(), d.pending_timers()),
          (1, 0, 0),
        )
      }
    }
  })
}

///|
test "Pong dispatch races a sender and retains prefetched bytes across another Ping" {
  @sim.explore(schedule => {
    for sender in [false, true] {
      let d = @driver.Driver::new(schedule~)
      let (conn, peer) = controlled(d)
      let s = session(d, conn)
      let sends : Array[@driver.Task] = []
      d.run(() => {
        if sender {
          conn.on_read = Some(() => {
            sends.push(d.spawn(() => s.send(Text("busy"))))
          })
        }
        peer.write(packet(Ping, b"first") + packet(Ping, b"second"))
        let receiver = d.spawn(() => {
          assert_eq(s.recv(), @ws.Message::Binary(b"end"))
        })
        conn.entered.wait()
        conn.on_read = Some(() => conn.release.notify())
        peer.write(packet(Binary, b"end"))
        ignore(receiver.wait())
        for send in sends {
          ignore(send.wait())
        }
        assert_eq(d.now(), 0L)
        assert_true(conn.writes.length() >= 2)
        s.abort()
        peer.close()
      })
      assert_eq((d.live_tasks(), d.pending_timers()), (0, 0))
    }
  })
  let d = @driver.Driver::new()
  let (conn, peer) = controlled(d)
  let s = session(d, conn)
  d.run(() => {
    peer.write(
      packet(Ping, b"x") + packet(Text, b"first") + packet(Binary, b"second"),
    )
    let receiver = d.spawn(() => {
      assert_eq(s.recv(), @ws.Message::Text("first"))
      assert_eq(s.recv(), @ws.Message::Binary(b"second"))
    })
    conn.entered.wait()
    conn.release.notify()
    ignore(receiver.wait())
    s.abort()
    peer.close()
  })
  assert_eq((d.live_tasks(), d.pending_timers()), (0, 0))
  for release in [false, true] {
    let d = @driver.Driver::new()
    let (conn, peer) = controlled(d)
    let s = session(d, conn, limits={ ..limits(), send_timeout_ms: 5, })
    d.run(() => {
      peer.write(packet(Ping, b"x"))
      let receiver = d.spawn(() => {
        if release {
          assert_eq(s.recv(), @ws.Message::Text("first"))
          assert_eq(s.recv(), @ws.Message::Binary(b"second"))
        } else {
          let timed_out = try {
            ignore(s.recv())
            false
          } catch {
            @ws.WsError(kind=Timeout(ms=5), ..) => true
            e => raise e
          }
          assert_true(timed_out)
        }
      })
      conn.entered.wait()
      peer.write(packet(Text, b"first") + packet(Binary, b"second"))
      // The full chunk drives the post-message read-ahead to 64 KiB and
      // one byte beyond. The short chunk leaves it waiting at expiry,
      // checking that abort discards input retained by cancellation cleanup.
      peer.write(
        packet(Binary, Bytes::make(if release { 65533 } else { 4 }, b'x')),
      )
      if release {
        let _ = d.add_timer(1L, () => conn.release.notify())
      }
      ignore(receiver.wait())
      assert_eq(d.now(), if release { 1L } else { 5L })
      s.abort()
      peer.close()
    })
    assert_eq(
      (conn.inner.closes(), peer.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  }
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
    for (send_ms, close_ms) in [(30000, 5), (5, 30000), (5, 5)] {
      for opcode in [@frame.Opcode::Ping, @frame.Opcode::Close] {
        let d = @driver.Driver::new(schedule~)
        let (conn, peer) = controlled(d)
        let s = session(d, conn, limits={
          ..limits(),
          send_timeout_ms: send_ms,
          close_timeout_ms: close_ms,
        })
        d.run(() => {
          peer.write(
            packet(opcode, if opcode is Close { b"\x03\xe8" } else { b"x" }),
          )
          let reader = d.spawn(() => {
            let _ = s.recv()
          })
          conn.entered.wait()
          reader.cancel()
          ignore(reader.wait())
          assert_true(reader.is_cancelled())
          assert_eq(d.now(), send_ms.min(close_ms).to_int64())
          assert_eq(conn.inner.closes(), 1)
          s.abort()
          peer.close()
        })
        assert_eq((d.live_tasks(), d.pending_timers()), (0, 0))
      }
    }
  })
}

///|
test "a peer that stops reading Pong cannot hold cancelled recv past close timeout or abort" {
  @sim.explore(schedule => {
    for abort in [false, true] {
      let d = @driver.Driver::new(schedule~)
      let c = @sim.SimCoordination::new(d)
      let (a, b) = @sim.pair(c)
      let ab = PressureSlot::{
        remaining: 0,
        closed: false,
        changed: c.signal(),
        coordination: c,
      }
      let ba = PressureSlot::{
        remaining: 0,
        closed: false,
        changed: c.signal(),
        coordination: c,
      }
      let conn = PressureConn::{
        inner: a,
        input: ba,
        output: ab,
        piece_bytes: 1,
      }
      let peer = PressureConn::{
        inner: b,
        input: ab,
        output: ba,
        piece_bytes: 64,
      }
      let s = session(d, conn, limits={ ..limits(), close_timeout_ms: 5, })
      d.run(() => {
        @rt.Conn::write(peer, packet(Ping, b"x"))
        let reader = d.spawn(() => {
          let _ = s.recv()
        })
        // Consume only the first Pong byte, leaving the rest backpressured.
        assert_eq(@rt.Conn::read(peer, max_len=1), Some(b"\x8a"))
        reader.cancel()
        if abort {
          s.abort()
        }
        ignore(reader.wait())
        assert_true(reader.is_cancelled())
        assert_eq(d.now(), if abort { 0L } else { 5L })
        assert_eq(a.closes(), 1)
        @rt.Conn::close(peer)
      })
      assert_eq(
        (a.closes(), b.closes(), d.live_tasks(), d.pending_timers()),
        (1, 1, 0, 0),
      )
    }
  })
}

///|
test "abort immediately releases protected Pong and Close writes even after recv cancellation" {
  @sim.explore(schedule => {
    for opcode in [@frame.Opcode::Ping, @frame.Opcode::Close] {
      for cancel in [false, true] {
        let d = @driver.Driver::new(schedule~)
        let (conn, peer) = controlled(d)
        let s = session(d, conn)
        d.run(() => {
          peer.write(
            packet(opcode, if opcode is Close { b"\x03\xe8" } else { b"x" }),
          )
          let reader = d.spawn(() => {
            ignore(
              s.recv() catch {
                @ws.WsError(..) => @ws.Message::Binary(b"")
              },
            )
          })
          conn.entered.wait()
          if cancel {
            reader.cancel()
            d.pause()
            assert_false(reader.is_finished())
          }
          s.abort()
          ignore(reader.wait())
          assert_eq((d.now(), conn.inner.closes()), (0L, 1))
          peer.close()
        })
        assert_eq((d.live_tasks(), d.pending_timers()), (0, 0))
      }
    }
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

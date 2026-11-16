///|
test "an uncongested receiver answers every Ping in a single input batch" {
  let d = @driver.Driver::new()
  let c = @sim.SimCoordination::new(d)
  let (conn, peer) = @sim.pair(c)
  let s = session(d, conn)
  d.run(() => {
    let wire = Buffer()
    for i in 0..<10 {
      wire.write_bytes(packet(Ping, Bytes::make(1, i.to_byte())))
    }
    wire.write_bytes(packet(Text, b"end"))
    peer.write(wire.to_bytes())
    assert_eq(s.recv(), @ws.Message::Text("end"))
    for i in 0..<10 {
      let (head, payload) = read_packet(peer)
      assert_true(head.opcode is Pong)
      assert_eq(payload, Bytes::make(1, i.to_byte()))
    }
    s.abort()
    peer.close()
  })
}

///|
test "senders queue FIFO queued cancellation removes its ticket and later senders progress" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let c = @sim.SimCoordination::new(d)
    let (conn, peer) = controlled(d)
    let s = session(d, conn)
    d.run(() => {
      let owner = d.spawn(() => s.send(Text("first")))
      conn.entered.wait()
      let second_entered = c.signal()
      let second = d.spawn(() => {
        second_entered.notify()
        s.send(Text("cancelled"))
      })
      second_entered.wait()
      let third_entered = c.signal()
      let third = d.spawn(() => {
        third_entered.notify()
        s.send(Text("third"))
      })
      third_entered.wait()
      second.cancel()
      ignore(second.wait())
      assert_eq(conn.inner.closes(), 0)
      conn.release.notify()
      ignore(owner.wait())
      ignore(third.wait())
      assert_eq(conn.writes.length(), 2)
      assert_eq(read_packet(peer).1, b"first")
      assert_eq(read_packet(peer).1, b"third")
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
test "a Ping flood retains only the latest pending Pong behind a blocked sender" {
  @sim.explore(schedule => {
    for count in [1, 2, 1024] {
      let d = @driver.Driver::new(schedule~)
      let (conn, peer) = controlled(d)
      let s = session(d, conn)
      let wire = Buffer()
      for i in 0..<count {
        wire.write_bytes(packet(Ping, Bytes::make(1, (i % 251).to_byte())))
      }
      wire.write_bytes(packet(Text, b"end"))
      let peak = Ref(0)
      d.run(() => {
        let writer = d.spawn(() => s.send(Text("busy")))
        conn.entered.wait()
        peer.write(wire.to_bytes())
        let receiver = d.spawn(() => {
          assert_eq(s.recv(), @ws.Message::Text("end"))
        })
        let _ = d.add_timer(1L, () => {
          peak.val = d.live_tasks()
          conn.release.notify()
        })
        ignore(writer.wait())
        ignore(receiver.wait())
        assert_eq(conn.writes.length(), 2)
        assert_eq(read_packet(peer).1, b"busy")
        let (head, pong) = read_packet(peer)
        assert_true(head.opcode is Pong)
        assert_eq(pong, Bytes::make(1, ((count - 1) % 251).to_byte()))
        assert_true(peak.val <= 12)
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
test "send deadline admits completion before bound and rejects at bound and plus one" {
  for delay in [4, 5, 6] {
    let d = @driver.Driver::new()
    let (conn, peer) = controlled(d)
    let s = session(d, conn, limits={ ..limits(), send_timeout_ms: 5, })
    d.run(() => {
      let _ = d.add_timer(delay.to_int64(), () => conn.release.notify())
      let expired = try {
        s.send(Binary(b"x"))
        false
      } catch {
        @ws.WsError(kind=Timeout(ms=5), ..) => true
        e => raise e
      }
      assert_eq(expired, delay >= 5)
      assert_eq(d.now(), if delay < 5 { 4L } else { 5L })
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
test "recv cancellation retains a partial frame and UTF8 sequence" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = @sim.pair(@sim.SimCoordination::new(d), chunk_bytes=1)
    let s = session(d, conn)
    d.run(() => {
      peer.write(b"\x01\x02\xf0")
      let reader = d.spawn(() => {
        let _ = s.recv()
      })
      let _ = d.add_timer(1L, () => reader.cancel())
      ignore(reader.wait())
      assert_eq(conn.closes(), 0)
      peer.write(b"\x9f\x80\x02\x99\x82")
      assert_eq(s.recv(), @ws.Message::Text("🙂"))
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
test "cancelled recv finishes the Close reply and preserves the peers Close status" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = controlled(d)
    let s = session(d, conn)
    d.run(() => {
      peer.write(packet(Close, b"\x03\xe9bye"))
      let reader = d.spawn(() => {
        let _ = s.recv()
      })
      conn.entered.wait()
      reader.cancel()
      d.pause()
      assert_false(reader.is_finished())
      conn.release.notify()
      ignore(reader.wait())
      assert_eq(read_packet(peer).1, b"\x03\xe9bye")
      let status = try {
        ignore(s.recv())
        None
      } catch {
        @ws.WsError(kind=Closed(frame), ..) => Some(frame)
        e => raise e
      }
      assert_eq(
        status,
        Some(@ws.CloseFrame::{ code: GoingAway, reason: "bye", }),
      )
      assert_eq(conn.writes.length(), 1)
      peer.close()
    })
    assert_eq(
      (conn.inner.closes(), peer.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  })
}

///|
test "transport write errors retain their identity and dispose of the connection" {
  let d = @driver.Driver::new()
  let cause = @mttp_core.TransportError(
    kind=Network,
    phase=Write,
    detail="injected",
  )
  let conn = @sim.ScriptedConn::new([], write_error=cause)
  let s = session(d, conn)
  let seen = d.run(() => {
    try {
      s.send(Text("x"))
      false
    } catch {
      @ws.WsError(kind=Transport(actual), ..) => {
        let @mttp_core.TransportError(detail~, ..) = actual
        detail == "injected"
      }
      e => raise e
    }
  })
  assert_true(seen)
  assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
}

///|
test "concurrent recv is refused and the cancelled owner can be retried" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = @sim.pair(@sim.SimCoordination::new(d))
    let s = session(d, conn)
    d.run(() => {
      let receiver = d.spawn(() => {
        let _ = s.recv()
      })
      d.sleep(1)
      let refused = try {
        ignore(s.recv())
        false
      } catch {
        @ws.WsError(kind=Protocol, ..) => true
        e => raise e
      }
      assert_true(refused)
      receiver.cancel()
      ignore(receiver.wait())
      peer.write(packet(Text, b"next"))
      assert_eq(s.recv(), @ws.Message::Text("next"))
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
test "concurrent local close calls share the active receiver and send Close once" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = controlled(d)
    conn.stalled = false
    let s = session(d, conn)
    d.run(() => {
      let receiver = d.spawn(() => {
        let ended = try {
          ignore(s.recv())
          false
        } catch {
          @ws.WsError(kind=Closed({ code: Normal, .. }), ..) => true
          e => raise e
        }
        assert_true(ended)
      })
      d.sleep(1)
      let first = d.spawn(() => s.close({ code: Normal, reason: "first", }))
      assert_true(read_packet(peer).0.opcode is Close)
      let second = d.spawn(() => s.close({ code: GoingAway, reason: "second", }))
      d.sleep(1)
      peer.write(packet(Close, b"\x03\xe8"))
      ignore(receiver.wait())
      ignore(first.wait())
      ignore(second.wait())
      assert_eq(conn.writes.length(), 1)
      peer.close()
    })
    assert_eq(
      (conn.inner.closes(), peer.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  })
}

///|
test "a queued sender is refused after Close starts and the writer still sends one Close" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let c = @sim.SimCoordination::new(d)
    let (conn, peer) = controlled(d)
    let s = session(d, conn)
    d.run(() => {
      let first = d.spawn(() => s.send(Text("first")))
      conn.entered.wait()
      let entered = c.signal()
      let second = d.spawn(() => {
        entered.notify()
        let refused = try {
          s.send(Text("late"))
          false
        } catch {
          @ws.WsError(kind=Closed(_), ..) => true
          e => raise e
        }
        assert_true(refused)
      })
      entered.wait()
      let closing = d.spawn(() => s.close({ code: Normal, reason: "", }))
      d.sleep(1)
      conn.release.notify()
      assert_eq(read_packet(peer).1, b"first")
      assert_true(read_packet(peer).0.opcode is Close)
      peer.write(packet(Close, b"\x03\xe8"))
      ignore(first.wait())
      ignore(second.wait())
      ignore(closing.wait())
      assert_eq(conn.writes.length(), 2)
      peer.close()
    })
    assert_eq(
      (conn.inner.closes(), peer.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  })
}

///|
test "abort wakes a blocked writer and refuses queued sends without extra frames" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let c = @sim.SimCoordination::new(d)
    let (conn, peer) = controlled(d)
    let s = session(d, conn)
    let failures = Ref(0)
    d.run(() => {
      let first = d.spawn(() => {
        s.send(Text("first")) catch {
          _ => failures.val += 1
        }
      })
      conn.entered.wait()
      let entered = c.signal()
      let second = d.spawn(() => {
        entered.notify()
        s.send(Text("second")) catch {
          _ => failures.val += 1
        }
      })
      entered.wait()
      s.abort()
      ignore(first.wait())
      ignore(second.wait())
      assert_eq(failures.val, 2)
      assert_eq(conn.writes.length(), 1)
      peer.close()
    })
    assert_eq(
      (conn.inner.closes(), peer.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  })
}

///|
test "Close racing a scheduled Pong flush suppresses the Pong after closing" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let selected : Ref[&@ws.Session?] = Ref(None)
    let closing : Ref[@driver.Task?] = Ref(None)
    let extension = TestExtension::{
      encode_fn: b => (b, false),
      decode_fn: (b, _, _) => {
        if selected.val is Some(s) {
          closing.val = Some(
            d.spawn(() => s.close({ code: Normal, reason: "", })),
          )
        }
        b
      },
    }
    let conn = @sim.ScriptedConn::new([
      Chunk(
        packet(Ping, b"x") + packet(Text, b"done") + packet(Close, b"\x03\xe8"),
      ),
    ])
    let s = session(d, conn, extension~)
    selected.val = Some(s)
    d.run(() => {
      ignore(
        s.recv() catch {
          @ws.WsError(kind=Closed(_), ..) => @ws.Message::Text("closed")
          e => raise e
        },
      )
      guard closing.val is Some(task) else { fail("decoder did not run") }
      ignore(task.wait())
    })
    assert_eq(
      conn.written().filter(bytes => (bytes[0].to_int() & 15) == 8).length(),
      1,
    )
    assert_true(conn.written().length() <= 2)
    assert_eq((conn.closes(), d.live_tasks(), d.pending_timers()), (1, 0, 0))
  })
}

///|
test "a Ping arriving during a blocked Pong is flushed next without another notification" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (conn, peer) = controlled(d)
    let s = session(d, conn)
    d.run(() => {
      peer.write(packet(Ping, b"first"))
      let reader = d.spawn(() => assert_eq(s.recv(), @ws.Message::Text("end")))
      conn.entered.wait()
      peer.write(packet(Ping, b"second"))
      let _ = d.add_timer(d.now() + 1L, () => conn.release.notify())
      assert_eq(read_packet(peer).1, b"first")
      assert_eq(read_packet(peer).1, b"second")
      assert_eq(d.now(), 1L)
      peer.write(packet(Text, b"end"))
      ignore(reader.wait())
      assert_eq(conn.writes.length(), 2)
      s.abort()
      peer.close()
    })
    assert_eq(
      (conn.inner.closes(), peer.closes(), d.live_tasks(), d.pending_timers()),
      (1, 1, 0, 0),
    )
  })
}

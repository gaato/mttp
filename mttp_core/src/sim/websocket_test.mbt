///|
test "websocket stub exchanges messages and closes both ends with the same status" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (left, right) = @sim.WebSocketStub::pair(
      @sim.SimCoordination::new(d),
      subprotocol="chat",
    )
    assert_eq(left.subprotocol(), Some("chat"))
    d.run(() => {
      left.send(Text("one"))
      left.send(Binary(b"\x00\xff"))
      assert_eq(right.recv(), @ws.Message::Text("one"))
      assert_eq(right.recv(), @ws.Message::Binary(b"\x00\xff"))
      right.send(Text("reply"))
      assert_eq(left.recv(), @ws.Message::Text("reply"))
      left.close({ code: Normal, reason: "done", })
      right.abort()
      for s in [left, right] {
        let ended = try {
          ignore(s.recv())
          false
        } catch {
          @ws.WsError(kind=Closed({ code: Normal, reason: "done", }), ..) =>
            true
          e => raise e
        }
        assert_true(ended)
        let refused = try {
          s.send(Text("late"))
          false
        } catch {
          @ws.WsError(kind=Closed(_), ..) => true
          e => raise e
        }
        assert_true(refused)
      }
    })
    assert_eq((d.live_tasks(), d.pending_timers()), (0, 0))
  })
}

///|
test "websocket stub recv cancellation is retryable and concurrent recv is refused" {
  @sim.explore(schedule => {
    let d = @driver.Driver::new(schedule~)
    let (left, right) = @sim.WebSocketStub::pair(@sim.SimCoordination::new(d))
    assert_eq(left.subprotocol(), None)
    d.run(() => {
      let reader = d.spawn(() => {
        let _ = left.recv()
      })
      d.sleep(1)
      let refused = try {
        ignore(left.recv())
        false
      } catch {
        @ws.WsError(kind=Protocol, ..) => true
        e => raise e
      }
      assert_true(refused)
      reader.cancel()
      ignore(reader.wait())
      right.send(Text("kept"))
      assert_eq(left.recv(), @ws.Message::Text("kept"))
      left.abort()
      right.abort()
      let aborted = try {
        ignore(right.recv())
        false
      } catch {
        @ws.WsError(kind=Closed({ code: Abnormal, .. }), ..) => true
        e => raise e
      }
      assert_true(aborted)
    })
    assert_eq((d.live_tasks(), d.pending_timers()), (0, 0))
  })
}

///|
test "an invalid stub Close aborts the pair without raising" {
  let d = @driver.Driver::new()
  let (left, right) = @sim.WebSocketStub::pair(@sim.SimCoordination::new(d))
  d.run(() => {
    left.close({ code: Other(1004), reason: "reserved", })
    right.close({ code: Normal, reason: "late", })
    let aborted = try {
      ignore(right.recv())
      false
    } catch {
      @ws.WsError(kind=Closed({ code: Abnormal, .. }), ..) => true
      e => raise e
    }
    assert_true(aborted)
  })
}

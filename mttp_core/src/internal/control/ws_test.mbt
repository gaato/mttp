///|
test "websocket close snapshots are immutable Closed absorbs and Close is sent once" {
  for seed in 0UL..<80UL {
    let mut state = @control.WsCloseState::new()
    let mut sent = 0
    for op in @qc.int_range(0, 8).array_with_size(100).sample(seed~) {
      let before = state
      let snapshot = (before.phase, before.sent, before.received)
      let (next, action) = match op {
        0 | 1 => (state.request(), false)
        2 | 3 => state.send()
        4 | 5 => (state.receive(), false)
        6 => (state, false)
        _ => (state.finish(), false)
      }
      sent += if action { 1 } else { 0 }
      assert_true(sent <= 1)
      assert_eq((before.phase, before.sent, before.received), snapshot)
      if before.phase is Closed {
        assert_eq(next, before)
        assert_false(action)
      }
      if next.sent || !(next.phase is Open) {
        assert_false(next.data_allowed())
      }
      state = next
    }
  }
  let local_close = @control.WsCloseState::new().request().receive()
  assert_eq(local_close.phase, @control.WsClosing::Closing(locally=true))
  let remote_close = @control.WsCloseState::new().receive()
  assert_eq(remote_close.phase, @control.WsClosing::Closing(locally=false))
}

///|
test "websocket fragment transitions agree with a reference model across controls" {
  for seed in 0UL..<80UL {
    let mut state = @control.WsAssembly::Idle
    let mut message : @control.WsData? = None
    for op in @qc.int_range(0, 8).array_with_size(100).sample(seed~) {
      let before = state
      if op >= 6 {
        continue
      } // Ping, Pong and Close do not enter data assembly.
      let kind = match op / 2 {
        0 => Some(@control.WsData::Text)
        1 => Some(@control.WsData::Binary)
        _ => None
      }
      let fin = op % 2 == 0
      let valid = (message is None && kind is Some(_)) ||
        (message is Some(_) && kind is None)
      let result = state.data(kind, fin~)
      assert_eq(result is Some(_), valid)
      assert_eq(state, before)
      if result is Some((next, actual)) {
        assert_eq(Some(actual), if kind is None { message } else { kind })
        message = if fin { None } else { Some(actual) }
        state = next
        assert_eq(state is Idle, message is None)
      }
    }
  }
}

///|
test "websocket life checks exact deadlines any byte and absorbing zombie" {
  let alive = @control.WsLife::Alive(0L)
  assert_eq(alive.tick(2L, Some(3), Some(2)), (alive, false))
  let (waiting, ping) = alive.tick(3L, Some(3), Some(2))
  assert_true(ping)
  assert_eq(waiting.sent(4L), @control.WsLife::Waiting(4L))
  assert_eq(alive.sent(4L), alive)
  assert_eq(@control.WsLife::Zombie.sent(4L), @control.WsLife::Zombie)
  assert_eq(
    alive.tick(4L, Some(3), Some(2)),
    (@control.WsLife::Waiting(4L), true),
  )
  assert_eq(
    waiting.tick(6L, Some(3), Some(2)),
    (@control.WsLife::Zombie, false),
  )
  assert_eq(waiting.tick(4L, Some(3), Some(2)), (waiting, false))
  assert_eq(
    waiting.tick(5L, Some(3), Some(2)),
    (@control.WsLife::Zombie, false),
  )
  assert_eq(waiting.received(4L), @control.WsLife::Alive(4L))
  assert_eq(alive.tick(100L, None, Some(2)), (alive, false))
  assert_eq(alive.tick(100L, Some(3), None), (alive, false))
  assert_eq(alive.tick(100L, Some(0), Some(2)), (alive, false))
  for seed in 0UL..<40UL {
    let mut state = alive
    let mut now = 0L
    for byte in @qc.int_range(0, 5).array_with_size(80).sample(seed~) {
      let before = state
      now += byte.to_int64()
      state = if byte == 0 {
        state.received(now)
      } else {
        state.tick(now, Some(3), Some(2)).0
      }
      if before is Zombie {
        assert_eq(state, before)
      }
    }
  }
}

///|
test "slot snapshots keep admission and cancellation independent" {
  let initial = @control.SlotState::new(max_total=2, max_per_origin=1)
  let a = initial.acquire(1L, "a").state
  let queued = a.acquire(2L, "a").state
  let b = queued.acquire(3L, "b").state
  assert_eq(initial.in_use, 0)
  assert_eq(a.waiting.length(), 0)
  assert_eq(queued.waiting.length(), 1)
  assert_eq(b.in_use, 2)
  let cancelled = b.abandon(2L).state
  let released = cancelled.release("a").state
  assert_eq(released.in_use, 1)
  assert_eq(b.waiting.length(), 1)
  let grant = b.release("a")
  assert_eq(grant.notifications.length(), 1)
  let (id, outcome) = grant.notifications[0]
  assert_eq(id, 2L)
  assert_true(outcome is Granted)
  assert_eq(grant.state.in_use, 2)
  let closed = b.stop()
  assert_eq(closed.notifications.length(), 1)
  assert_eq(closed.state.waiting.length(), 0)
  assert_true(closed.state.acquire(4L, "c").notifications[0].1 is Refused)
  assert_false(b.closed)
}

///|
test "slot event sequences preserve bounds and previous snapshots" {
  let mut state = @control.SlotState::new(max_total=4, max_per_origin=2)
  for id in 1L..<1001L {
    let old = state
    let count = old.in_use
    let waiting = old.waiting.length()
    let origin = if id % 3L == 0L { "a" } else { "b" }
    state = state.acquire(id, origin).state
    if id % 2L == 0L {
      state = state.release("a").state
    }
    if id % 3L == 0L {
      state = state.release("b").state
    }
    if id % 5L == 0L {
      state = state.abandon(id).state
    }
    assert_eq(old.in_use, count)
    assert_eq(old.waiting.length(), waiting)
    assert_true(state.in_use >= 0 && state.in_use <= 4)
    let mut total = 0
    for _, used in state.per_origin {
      assert_true(used > 0 && used <= 2)
      total += used
    }
    assert_eq(total, state.in_use)
  }
  assert_eq(state.stop().state.waiting.length(), 0)
}

///|
test "pool snapshots isolate reuse eviction and backwards time" {
  let empty = @control.PoolState::new(
    max_total=2,
    max_per_origin=2,
    idle_max_ms=10,
  )
  let one = empty.put(
      "a",
      { id: 1L, user_agent: Some("a"), parked_at_ms: 10L, },
      now=10L,
    ).state
  let two = one.put(
      "a",
      { id: 2L, user_agent: Some("b"), parked_at_ms: 12L, },
      now=12L,
    ).state
  let (take, id) = two.take("a", Some("a"), now=9L)
  assert_eq(id, Some(1L))
  assert_eq(take.close.length(), 0)
  assert_eq(take.state.count(), 1)
  assert_eq(empty.count(), 0)
  assert_eq(one.count(), 1)
  assert_eq(two.count(), 2)
  let full = two.put(
    "b",
    { id: 3L, user_agent: None, parked_at_ms: 13L, },
    now=13L,
  )
  assert_eq(full.close[0], 3L)
  let expired = two.sweep(now=20L)
  assert_eq(expired.close[0], 1L)
  assert_eq(expired.state.count(), 1)
  let drained = two.drain()
  assert_eq(drained.close.length(), 2)
  assert_eq(drained.state.drain().close.length(), 0)
  assert_eq(
    drained.state.put(
      "a",
      { id: 4L, user_agent: None, parked_at_ms: 20L, },
      now=20L,
    ).close[0],
    4L,
  )
  assert_false(two.closed)
}

///|
test "FIN preserves an active response while a read failure cancels it" {
  let idle = @control.SessionState::new()
  let active = idle.step(Begin).state
  let fin = active.step(PeerEof)
  assert_false(fin.cancel_exchange)
  assert_true(fin.state.busy)
  assert_true(fin.state.peer_eof)
  assert_false(active.peer_eof)
  assert_true(active.step(PeerFailure).cancel_exchange)
  assert_false(idle.step(PeerFailure).cancel_exchange)
}

///|
test "shutdown accept races are explicit in both delivery orders" {
  let initial = @control.Lifecycle::new()
  let accepted = initial.step(Accepted(1L)).state
  let stopping = accepted.step(Stop)
  assert_eq(stopping.actions.length(), 3)
  assert_true(stopping.actions[0] is StopAccept)
  assert_eq(stopping.state.connections.length(), 1)
  assert_false(initial.stopping())
  let rejected = initial.step(Stop).state.step(Accepted(1L))
  assert_eq(rejected.state.connections.length(), 0)
  assert_eq(rejected.actions.length(), 2)
  assert_true(initial.step(AcceptFailed).actions[0] is ReportAccept)
  assert_eq(stopping.state.step(AcceptFailed).actions.length(), 0)
  assert_eq(stopping.state.step(Stop).actions.length(), 0)
  assert_eq(initial.step(Activity(99L, false)).actions.length(), 0)
}

///|
test "drain finishes busy exchanges and tracks background work until expiry" {
  let active = @control.Lifecycle::new().step(Accepted(1L)).state.step(
      Activity(1L, true),
    ).state
  let state = active.step(BackgroundStarted(2L)).state.step(Stop)
  assert_eq(state.actions.length(), 1)
  assert_false(state.state.drained())
  let idle = state.state.step(Activity(1L, false))
  assert_eq(idle.actions.length(), 2)
  let finished = idle.state.step(Finished(1L)).state
  assert_false(finished.drained())
  assert_true(finished.step(BackgroundFinished(2L)).state.drained())
  let expired = state.state.step(DrainExpired)
  assert_eq(expired.actions.length(), 3)
  assert_eq(expired.state.step(DrainExpired).actions.length(), 0)
  assert_true(
    expired.state.step(BackgroundStarted(3L)).actions[0] is CancelBackground(3L),
  )
  assert_eq(active.connections.length(), 1)
  assert_eq(active.background.length(), 0)
}

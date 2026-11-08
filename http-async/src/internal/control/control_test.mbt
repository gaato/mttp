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

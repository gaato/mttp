// The wait primitive, on gaato/mttp's runtime.

///|
fn changes() -> (@mux.Changes, &@rt.Clock) {
  let clock = @runtime.AsyncClock::new()
  (
    @mux.Changes::new(
      @runtime.RuntimeCoordination::new(),
      clock,
      @runtime.ClockTimer::new(clock~),
    ),
    clock,
  )
}

///|
async test "a change wakes the waiter, which sees the new state" {
  let (changes, _) = changes()
  let flag = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      @async.sleep(20)
      flag.val = true
      changes.notify()
    })
    assert_true(changes.wait_until(() => flag.val))
  })
}

///|
async test "wake-ups that leave the condition false do not move the deadline" {
  let (changes, clock) = changes()
  let stop = Ref(false)
  @async.with_task_group(group => {
    // Unrelated traffic: a change every 10 ms, for longer than the wait.
    group.spawn_bg(() => {
      while !stop.val {
        @async.sleep(10)
        changes.notify()
      }
    })
    let start = clock.now_unix_ms()
    let done = changes.wait_until(
      () => false,
      deadline=changes.deadline_in(100),
    )
    let took = clock.now_unix_ms() - start
    stop.val = true
    assert_false(done)
    assert_true(took >= 90L)
    assert_true(took < 1000L)
  })
}

///|
async test "a deadline already past looks at the condition once" {
  let (changes, _) = changes()
  assert_true(changes.wait_until(() => true, deadline=changes.deadline_in(0)))
  assert_false(changes.wait_until(() => false, deadline=changes.deadline_in(0)))
}

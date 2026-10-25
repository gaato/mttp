///|
test "cancelling a timer caller cancels its child and disarms deadline" {
  let d = @driver.Driver::new()
  let timer = @fake.SimTimer::new(d)
  let mut cleaned = false
  d.run(() => {
    let caller = d.spawn(() => {
      let _ = timer.within(100, () => {
        defer {
          cleaned = true
        }
        d.sleep(200)
      })
    })
    d.pause()
    d.pause()
    caller.cancel()
    assert_false(caller.wait())
  })
  assert_true(cleaned)
  assert_eq(d.pending_timers(), 0)
  assert_eq(d.live_tasks(), 0)
}

///|
test "fake clock records sleeps and returns a snapshot" {
  let clock = @fake.FakeClock::new(start_unix_ms=7)
  @driver.run_sync(() => {
    clock.sleep(-2)
    clock.sleep(0)
    clock.sleep(5)
  })
  assert_eq(clock.now_unix_ms(), 12)
  clock.advance(-3)
  assert_eq(clock.now_unix_ms(), 9)
  let copy = clock.slept()
  copy.clear()
  assert_eq(clock.slept(), [-2, 0, 5])
}

///|
test "sim clock concurrent sleeps overlap" {
  let d = @driver.Driver::new(start_ms=100)
  let clock = @fake.SimClock::new(d)
  d.run(() => {
    let a = d.spawn(() => clock.sleep(20))
    let b = d.spawn(() => clock.sleep(30))
    assert_true(a.wait())
    assert_true(b.wait())
  })
  assert_eq(clock.now_unix_ms(), 130)
  assert_eq(d.pending_timers(), 0)
}

///|
test "timer nonpositive deadlines do not start callbacks" {
  let d = @driver.Driver::new()
  let timer = @fake.SimTimer::new(d)
  let mut called = false
  d.run(() => {
    assert_false(timer.within(0, () => called = true))
    assert_false(timer.within(-1, () => called = true))
  })
  assert_false(called)
}

///|
test "timer completion and timeout clean up children and timers" {
  let d = @driver.Driver::new()
  let timer = @fake.SimTimer::new(d)
  let mut cleaned = false
  d.run(() => {
    assert_true(timer.within(10, () => d.sleep(5)))
    assert_eq(d.now(), 5)
    assert_false(
      timer.within(10, () => {
        defer {
          cleaned = true
        }
        d.sleep(20)
      }),
    )
    assert_true(cleaned)
    assert_eq(d.now(), 15)
  })
  assert_eq(d.live_tasks(), 0)
  assert_eq(d.pending_timers(), 0)
}

///|
test "gate is FIFO and removes cancelled waiters" {
  let d = @driver.Driver::new()
  let gate = @fake.SimGate::new(d)
  let order = []
  d.run(() => {
    gate.acquire()
    let first = d.spawn(() => {
      gate.acquire()
      defer gate.release()
      order.push(1)
    })
    let cancelled = d.spawn(() => {
      gate.acquire()
      defer gate.release()
      order.push(2)
    })
    let last = d.spawn(() => {
      gate.acquire()
      defer gate.release()
      order.push(3)
    })
    d.pause()
    assert_eq(gate.waiting(), 3)
    cancelled.cancel()
    assert_false(cancelled.wait())
    assert_eq(gate.waiting(), 2)
    gate.release()
    assert_true(first.wait())
    assert_true(last.wait())
  })
  assert_eq(order, [1, 3])
  assert_eq(gate.available(), 1)
  assert_eq(gate.waiting(), 0)
  gate.release()
  assert_eq(gate.available(), 1)
}

///|
test "gate handoff followed by cancellation returns the permit" {
  let d = @driver.Driver::new()
  let gate = @fake.SimGate::new(d)
  let mut acquired = false
  d.run(() => {
    gate.acquire()
    let child = d.spawn(() => {
      gate.acquire()
      defer gate.release()
      acquired = true
      d.sleep(10)
    })
    d.pause()
    gate.release()
    child.cancel()
    assert_false(child.wait())
  })
  assert_true(acquired)
  assert_eq(gate.available(), 1)
}

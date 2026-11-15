///|
test "protection nests and cancellation remains pending after it returns" {
  let d = @driver.Driver::new()
  let events = []
  d.run(() => {
    let worker = d.spawn(() => {
      defer events.push("cleanup")
      d.protect(work=() => {
        d.sleep(2)
        d.protect(work=() => d.sleep(3))
        d.sleep(4)
        events.push("protected")
      })
      events.push("returned")
      d.pause()
      events.push("escaped")
    })
    d.pause()
    worker.cancel()
    worker.cancel()
    ignore(worker.wait())
    assert_true(worker.is_cancelled())
  })
  assert_eq(events, ["protected", "returned", "cleanup"])
  assert_eq((d.now(), d.live_tasks(), d.pending_timers()), (9L, 0, 0))
}

///|
test "driver shutdown finishes protected bounded cleanup on virtual time" {
  let d = @driver.Driver::new()
  let done = Ref(false)
  d.run(() => {
    let _ = d.spawn(() => {
      d.protect(work=() => {
        d.sleep(10)
        done.val = true
      })
      d.pause()
    })
    d.pause()
  })
  assert_true(done.val)
  assert_eq((d.now(), d.live_tasks(), d.pending_timers()), (10L, 0, 0))
}

///|
test "protection outside its driver never invokes the callback" {
  let idle = @driver.Driver::new()
  let called = Ref(false)
  let refused = try {
    @driver.run_sync(() => idle.protect(work=() => called.val = true))
    false
  } catch {
    @driver.DriverError(kind=NotInTask, ..) => true
    error => raise error
  }
  assert_true(refused)
  assert_false(called.val)
}

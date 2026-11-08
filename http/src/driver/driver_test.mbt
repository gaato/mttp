// Plain `test` blocks (no `async test`): every async computation runs on a
// @driver.Driver, so no async runtime is linked on any target.

///|
test "cleanup continues with a fresh round after a defer spawns a burst" {
  let d = @driver.Driver::new(max_steps=3)
  let mut finished = 0
  d.run(() => {
    let _ = d.spawn(() => {
      defer (for _ in 0..<50 {
        let _ = d.spawn(() => finished += 1)
      })
      d.sleep(100)
    })
    d.pause()
  })
  assert_eq(finished, 50)
  assert_eq(d.live_tasks(), 0)
}

///|
fn rearm_timer(d : @driver.Driver, fired : Ref[Int32]) -> Unit {
  let _ = d.add_timer(d.now(), () => {
    fired.val += 1
    if fired.val < 1000 {
      rearm_timer(d, fired)
    }
  })
}

///|
test "self-rearming due timers obey a callback budget" {
  let d = @driver.Driver::new(max_steps=10)
  let fired = Ref(0)
  rearm_timer(d, fired)
  let result = driver_error_kind(() => d.run(() => d.sleep(1)))
  guard result is Ok(NoQuiescence(..)) else { fail("wrong error") }
  assert_eq(fired.val, 10)
  assert_eq(d.live_tasks(), 0)
  assert_eq(d.pending_timers(), 0)
}

///|
test "timer callbacks cannot reenter step or run" {
  let d = @driver.Driver::new()
  let outcomes = []
  let _ = d.add_timer(0, () => {
    outcomes.push(driver_error_kind(() => ignore(d.step())))
    outcomes.push(driver_error_kind(() => d.run(() => ())))
  })
  d.run(() => ())
  for result in outcomes {
    guard result is Ok(Reentrant) else { fail("wrong error") }
  }
  assert_eq(outcomes.length(), 2)
}

///|
test "exhausted execution budget still unwinds ten thousand tasks" {
  let d = @driver.Driver::new(max_steps=10)
  let mut cleaned = 0
  let result = driver_error_kind(() => {
    d.run(() => {
      for _ in 0..<10_000 {
        let _ = d.spawn(() => {
          defer {
            cleaned += 1
          }
          d.sleep(100)
        })
      }
      d.sleep(1000)
    })
  })
  guard result is Ok(NoQuiescence(..)) else { fail("wrong error") }
  assert_eq(cleaned, 10_000)
  assert_eq(d.live_tasks(), 0)
  assert_eq(d.pending_timers(), 0)
}

///|
async fn join_all(tasks : Array[@driver.Task]) -> Unit {
  for t in tasks {
    let _ = t.wait()
  }
}

///|
/// Sleeps, then fails only when asked: gives `try` a body that can raise, so
/// the tests can show that cancellation is not caught by `catch`.
async fn sleep_then_maybe_fail(
  d : @driver.Driver,
  ms : Int32,
  fail_after~ : Bool,
) -> Unit {
  d.sleep(ms)
  if fail_after {
    fail("asked to fail")
  }
}

///|
/// The kind of a DriverError raised by `f`, or a description of what else
/// happened.
fn[X] driver_error_kind(
  f : () -> X raise,
) -> Result[@driver.DriverErrorKind, String] {
  try {
    let _ = f()
    Err("no error")
  } catch {
    @driver.DriverError(kind~, ..) => Ok(kind)
    e => Err("other error: \{e}")
  }
}

// A FIFO gate and a deadline helper built only on the public Driver API, as
// the clock/fake package's SimGate and SimTimer are.

///|
priv struct GateWaiter {
  mut waker : @driver.Waker?
  mut queued : Bool
}

///|
/// A counting gate with FIFO hand-over. `release` passes the permit straight
/// to the oldest waiter. Cancelling a queued waiter removes it from the
/// queue; a waiter handed the permit and cancelled before it resumes keeps
/// the permit, as moonbitlang/core's Semaphore does.
priv struct TestGate {
  driver : @driver.Driver
  size : Int32
  mut available : Int32
  queue : Array[GateWaiter]
  mut waiting : Int32
}

///|
fn TestGate::new(
  driver : @driver.Driver,
  permits~ : Int32 = 1,
  initial? : Int32,
) -> TestGate {
  let available = match initial {
    Some(n) => n
    None => permits
  }
  { driver, size: permits, available, queue: [], waiting: 0, }
}

///|
async fn TestGate::acquire(self : TestGate) -> Unit noraise {
  if self.available > 0 {
    self.available -= 1
    return
  }
  let w : GateWaiter = { waker: None, queued: true, }
  self.queue.push(w)
  self.waiting += 1
  match self.driver.park_check_cancel(wk => w.waker = Some(wk)) {
    Woken => ()
    Cancelled =>
      if w.queued {
        w.queued = false
        self.waiting -= 1
        @driver.raise_cancellation()
      }
    // Otherwise release already handed this waiter the permit: keep it.
    // The task still observes the cancellation at its next park.
  }
}

///|
fn TestGate::release(self : TestGate) -> Unit {
  while !self.queue.is_empty() {
    let w = self.queue.remove(0)
    if w.queued {
      w.queued = false
      self.waiting -= 1
      if w.waker is Some(k) {
        k.wake()
      }
      return
    }
  }
  if self.available < self.size {
    self.available += 1
  }
}

///|
/// Runs `f` holding one permit. `on_unwind` runs from an `errdefer` when `f`
/// (or the wait for the permit) unwinds by error or by cancellation; the
/// permit is released by a `defer`.
async fn[X] TestGate::with_permit(
  self : TestGate,
  f : async () -> X,
  on_unwind~ : () -> Unit = () => (),
) -> X {
  errdefer on_unwind()
  self.acquire()
  defer self.release()
  f()
}

///|
/// Runs `f` as a child task and waits for it. If `ms` of virtual time pass
/// first, the child is cancelled (its `defer`s run) and `within` returns
/// false once it has unwound.
async fn within(
  d : @driver.Driver,
  ms : Int32,
  f : async () -> Unit noraise,
) -> Bool noraise {
  let mut completed = false
  let child = d.spawn(
    () => {
      f()
      completed = true
    },
    label="within",
  )
  let timer = d.add_timer(d.now() + ms.to_int64(), () => {
    if !completed {
      child.cancel()
    }
  })
  defer {
    timer.cancel()
    if !child.is_finished() {
      child.cancel()
    }
  }
  let _ = child.wait() catch { _ => false }
  completed
}

///|
test "ready queue is FIFO" {
  let d = @driver.Driver::new()
  let log = []
  d.run(() => {
    let tasks = []
    for name in ["a", "b", "c"] {
      tasks.push(
        d.spawn(() => {
          log.push(name + "1")
          @driver.pause()
          log.push(name + "2")
        }),
      )
    }
    join_all(tasks)
  })
  assert_eq(log, ["a1", "b1", "c1", "a2", "b2", "c2"])
  assert_eq(d.live_tasks(), 0)
}

///|
test "run returns main's value and its error" {
  let d = @driver.Driver::new()
  assert_eq(
    d.run(() => {
      d.sleep(250)
      d.now()
    }),
    250L,
  )
  let r = try d.run(() => (fail("boom") : Int32)) catch {
    Failure(msg) => msg.contains("boom")
    _ => false
  } noraise {
    _ => false
  }
  assert_true(r)
}

///|
test "two tasks contend on a one-permit gate" {
  let d = @driver.Driver::new()
  let gate = TestGate::new(d, permits=1)
  let log = []
  d.run(() => {
    let a = d.spawn(() => {
      gate.acquire()
      log.push("a acquired @\{d.now()}")
      d.sleep(10)
      log.push("a releases @\{d.now()} waiting=\{gate.waiting}")
      gate.release()
    })
    let b = d.spawn(() => {
      gate.acquire()
      log.push("b acquired @\{d.now()}")
      d.sleep(5)
      gate.release()
    })
    join_all([a, b])
  })
  assert_eq(log, ["a acquired @0", "a releases @10 waiting=1", "b acquired @10"])
  assert_eq(d.now(), 15L)
  assert_eq(gate.available, 1)
  assert_eq(gate.waiting, 0)
}

///|
test "gate hands permits over in FIFO order" {
  let d = @driver.Driver::new()
  let gate = TestGate::new(d, permits=1)
  let order = []
  d.run(() => {
    let tasks = []
    for name in ["a", "b", "c", "d", "e"] {
      tasks.push(
        d.spawn(() => {
          gate.acquire()
          order.push("\{name}@\{d.now()}")
          d.sleep(3)
          gate.release()
        }),
      )
    }
    join_all(tasks)
  })
  assert_eq(order, ["a@0", "b@3", "c@6", "d@9", "e@12"])
}

///|
test "cancelling a queued waiter removes it from the gate" {
  let d = @driver.Driver::new()
  let gate = TestGate::new(d, permits=1)
  let log = []
  let mut waiting_before = -1
  let mut waiting_after = -1
  let mut b_completed = true
  d.run(() => {
    let a = d.spawn(() => {
      gate.acquire()
      d.sleep(100)
      gate.release()
    })
    let b = d.spawn(() => {
      defer log.push("b unwound")
      gate.acquire()
      log.push("b acquired")
      gate.release()
    })
    let c = d.spawn(() => {
      gate.acquire()
      log.push("c acquired @\{d.now()}")
      gate.release()
    })
    d.sleep(1)
    waiting_before = gate.waiting
    b.cancel()
    b_completed = b.wait()
    waiting_after = gate.waiting
    join_all([a, c])
  })
  assert_eq(waiting_before, 2)
  assert_eq(waiting_after, 1)
  assert_false(b_completed)
  assert_eq(log, ["b unwound", "c acquired @100"])
  assert_eq(gate.available, 1)
}

///|
test "wake-then-cancel keeps the permit, as core's semaphore does" {
  let d = @driver.Driver::new()
  let gate = TestGate::new(d, permits=1)
  let mut b_got_permit = false
  let mut b_after_pause = false
  let mut b_completed = true
  let mut waiting_while_held = -1
  let mut available_after_release = -1
  d.run(() => {
    gate.acquire()
    let b = d.spawn(() => {
      gate.acquire()
      b_got_permit = true
      defer gate.release()
      d.pause()
      b_after_pause = true
    })
    d.sleep(1)
    waiting_while_held = gate.waiting
    gate.release()
    // b has been handed the permit and is ready, but has not resumed.
    available_after_release = gate.available
    b.cancel()
    b_completed = b.wait()
  })
  assert_eq(waiting_while_held, 1)
  assert_eq(available_after_release, 0)
  assert_true(b_got_permit)
  assert_false(b_after_pause)
  assert_false(b_completed)
  assert_eq(gate.available, 1)
  assert_eq(gate.waiting, 0)
}

///|
test "within expires, cancels a sleeping child, and the child's defer runs" {
  let d = @driver.Driver::new()
  let log = []
  let mut caught = false
  let ok = d.run(() => {
    let ok = within(d, 100, () => {
      defer log.push("child defer @\{d.now()}")
      log.push("child start")
      sleep_then_maybe_fail(d, 1000, fail_after=false) catch {
        _ => caught = true
      }
      log.push("child after try")
    })
    log.push("within returned \{ok} @\{d.now()}")
    ok
  })
  assert_false(ok)
  assert_false(caught)
  assert_eq(log, [
    "child start", "child defer @100", "within returned false @100",
  ])
  assert_eq(d.now(), 100L)
}

///|
test "within that completes in time disarms its timer" {
  let d = @driver.Driver::new()
  let mut pending_after = -1
  let ok = d.run(() => {
    let ok = within(d, 100, () => d.sleep(40))
    pending_after = d.pending_timers()
    ok
  })
  assert_true(ok)
  assert_eq(pending_after, 0)
  // Time did not jump to the disarmed 100 ms deadline.
  assert_eq(d.now(), 40L)
}

///|
test "deadlines and sleeps share one virtual timeline" {
  let d = @driver.Driver::new(start_ms=1_700_000_000_000L)
  let r = d.run(() => {
    let fast = within(d, 10, () => d.sleep(5))
    let slow = within(d, 10, () => d.sleep(50))
    d.sleep(7)
    (fast, slow, d.now())
  })
  assert_eq(r, (true, false, 1_700_000_000_022L))
}

///|
test "errdefer in the test package runs when @driver raises cancellation" {
  let d = @driver.Driver::new()
  let log = []
  let mut caught = false
  let mut completed = true
  d.run(() => {
    let t = d.spawn(() => {
      errdefer log.push("test errdefer")
      defer log.push("test defer")
      sleep_then_maybe_fail(d, 1000, fail_after=true) catch {
        _ => caught = true
      }
      log.push("unreachable")
    })
    d.sleep(5)
    t.cancel()
    completed = t.wait()
  })
  assert_false(caught)
  assert_false(completed)
  assert_eq(log, ["test defer", "test errdefer"])
  assert_eq(d.now(), 5L)
}

///|
test "errdefer around a body runs when the body is cancelled" {
  let d = @driver.Driver::new()
  let gate = TestGate::new(d, permits=1)
  let log = []
  let mut held = -1
  d.run(() => {
    let t = d.spawn(() => {
      let _ = gate.with_permit(
        () => {
          log.push("in permit")
          d.sleep(1000)
          log.push("unreachable")
          1
        },
        on_unwind=() => log.push("gate errdefer"),
      )
      log.push("unreachable 2")
    })
    d.sleep(5)
    held = gate.available
    t.cancel()
    let _ = t.wait()
  })
  assert_eq(held, 0)
  assert_eq(log, ["in permit", "gate errdefer"])
  assert_eq(gate.available, 1)
}

///|
test "errdefer runs when a gate raises cancellation" {
  let d = @driver.Driver::new()
  let gate = TestGate::new(d, permits=1, initial=0)
  let log = []
  d.run(() => {
    let t = d.spawn(() => {
      errdefer log.push("errdefer around a queued acquire")
      gate.acquire()
      log.push("unreachable")
    })
    d.sleep(1)
    log.push("waiting=\{gate.waiting}")
    t.cancel()
    let _ = t.wait()
    log.push("waiting=\{gate.waiting}")
  })
  assert_eq(log, ["waiting=1", "errdefer around a queued acquire", "waiting=0"])
}

///|
test "errdefer does not run on normal completion" {
  let d = @driver.Driver::new()
  let gate = TestGate::new(d, permits=1)
  let log = []
  let v = d.run(() => {
    gate.with_permit(
      () => {
        d.sleep(1)
        7
      },
      on_unwind=() => log.push("gate errdefer"),
    )
  })
  assert_eq(v, 7)
  assert_eq(log.length(), 0)
  assert_eq(gate.available, 1)
}

///|
test "deadlock is detected and parked tasks are unwound" {
  let d = @driver.Driver::new()
  let gate = TestGate::new(d, permits=1, initial=0)
  let log = []
  let r = driver_error_kind(() => {
    d.run(() => {
      let _ = d.spawn(() => {
        defer log.push("child unwound")
        gate.acquire()
      })
      gate.acquire()
      0
    })
  })
  guard r is Ok(Deadlock(parked~)) else { fail("got \{@debug.to_string(r)}") }
  assert_eq(parked, 2)
  assert_eq(log, ["child unwound"])
  assert_eq(d.live_tasks(), 0)
  assert_eq(gate.waiting, 0)
}

///|
test "a pending timer is not a deadlock" {
  let d = @driver.Driver::new()
  let gate = TestGate::new(d, permits=1, initial=0)
  let r = d.run(() => {
    let _ = d.spawn(() => {
      d.sleep(30_000)
      gate.release()
    })
    gate.acquire()
    d.now()
  })
  assert_eq(r, 30_000L)
}

///|
test "livelock raises NoQuiescence" {
  let d = @driver.Driver::new(max_steps=1000)
  let r = driver_error_kind(() => {
    d.run(() => {
      while true {
        d.pause()
      }
    })
  })
  guard r is Ok(NoQuiescence(steps~)) else {
    fail("got \{@debug.to_string(r)}")
  }
  assert_eq(steps, 1001)
  assert_eq(d.live_tasks(), 0)
}

///|
test "a failing child fails run with TaskFailed" {
  let d = @driver.Driver::new()
  let r = driver_error_kind(() => {
    d.run(() => {
      let _ = d.spawn(
        () => {
          d.sleep(1)
          fail("child failed")
        },
        label="child",
      )
      d.sleep(10)
      "main finished"
    })
  })
  guard r is Ok(TaskFailed(label~, cause~)) else {
    fail("got \{@debug.to_string(r)}")
  }
  assert_eq(label, "child")
  guard cause is Failure(msg) else { fail("cause \{@debug.to_string(cause)}") }
  assert_true(msg.contains("child failed"))
}

///|
test "run_sync returns values and refuses to wait" {
  assert_eq(@driver.run_sync(() => 42), 42)
  assert_eq(
    @driver.run_sync(() => {
      @driver.pause()
      @driver.pause()
      "paused twice"
    }),
    "paused twice",
  )
  let r = driver_error_kind(() => @driver.run_sync(() => @driver.sleep(1)))
  guard r is Ok(Suspended(parked~)) else { fail("got \{@debug.to_string(r)}") }
  assert_eq(parked, 1)
  let r2 = try @driver.run_sync(() => (fail("sync failure") : Int32)) catch {
    Failure(msg) => msg.contains("sync failure")
    _ => false
  } noraise {
    _ => false
  }
  assert_true(r2)
}

///|
test "10_000 tasks and about 1_000_000 steps" {
  let d = @driver.Driver::new()
  let mut counter = 0
  d.run(() => {
    let tasks = []
    for _ in 0..<10_000 {
      tasks.push(
        d.spawn(() => {
          for _ in 0..<100 {
            d.pause()
            counter += 1
          }
        }),
      )
    }
    join_all(tasks)
  })
  assert_eq(counter, 1_000_000)
  // 10_000 x (1 start + 100 resumes) + 2 steps of main, on every target
  inspect(d.steps(), content="1010002")
  assert_eq(d.live_tasks(), 0)
}

///|
test "10_000 tasks through one gate with timers, in FIFO order" {
  let d = @driver.Driver::new()
  let gate = TestGate::new(d, permits=1)
  let order = []
  d.run(() => {
    let tasks = []
    for i in 0..<10_000 {
      tasks.push(
        d.spawn(() => {
          gate.acquire()
          order.push(i)
          d.sleep(1)
          gate.release()
        }),
      )
    }
    join_all(tasks)
  })
  assert_eq(order.length(), 10_000)
  let mut in_order = true
  for i in 0..<10_000 {
    if order[i] != i {
      in_order = false
    }
  }
  assert_true(in_order)
  assert_eq(d.now(), 10_000L)
}

///|
test "10_000 sleepers wake in deadline order" {
  let d = @driver.Driver::new()
  let woke = []
  d.run(() => {
    let tasks = []
    for i in 0..<10_000 {
      // spawned in reverse deadline order, with collisions every 7
      let ms = (10_000 - i) / 7
      tasks.push(
        d.spawn(() => {
          d.sleep(ms)
          woke.push(ms)
        }),
      )
    }
    join_all(tasks)
  })
  let mut sorted = true
  for i in 1..<woke.length() {
    if woke[i - 1] > woke[i] {
      sorted = false
    }
  }
  assert_eq(woke.length(), 10_000)
  assert_true(sorted)
}

///|
test "1_000_000 non-suspending async calls in one task" {
  let d = @driver.Driver::new()
  let gate = TestGate::new(d, permits=1)
  let mut n = 0
  d.run(() => {
    for _ in 0..<1_000_000 {
      gate.acquire()
      n += 1
      gate.release()
    }
  })
  assert_eq(n, 1_000_000)
}

///|
test "one task resumed 1_000_000 times" {
  let d = @driver.Driver::new()
  let n = d.run(() => {
    let mut n = 0
    for _ in 0..<1_000_000 {
      d.pause()
      n += 1
    }
    n
  })
  assert_eq(n, 1_000_000)
  inspect(d.steps(), content="1000001")
}

// ------------------------------------------- misuse raises, never aborts

///|
test "current and the ambient helpers raise NotInTask outside a step" {
  let d = @driver.Driver::new()
  guard driver_error_kind(() => @driver.current()) is Ok(NotInTask) else {
    fail("current")
  }
  guard driver_error_kind(() => @driver.now()) is Ok(NotInTask) else {
    fail("now")
  }
  guard driver_error_kind(() => @driver.spawn(() => ())) is Ok(NotInTask) else {
    fail("spawn")
  }
  guard driver_error_kind(() => d.current_task()) is Ok(NotInTask) else {
    fail("current_task")
  }
  // Inside a step they work, and the driver is usable afterwards.
  let (label, same) = d.run(() => {
    (d.current_task().label(), physical_equal(@driver.current(), d))
  })
  assert_eq(label, "main")
  assert_true(same)
  guard driver_error_kind(() => d.current_task()) is Ok(NotInTask) else {
    fail("current_task after run")
  }
}

///|
test "current_task of another driver raises NotInTask inside a task" {
  let d = @driver.Driver::new()
  let other = @driver.Driver::new()
  let r = d.run(() => driver_error_kind(() => other.current_task()))
  guard r is Ok(NotInTask) else { fail("got \{@debug.to_string(r)}") }
}

///|
test "parking on another driver fails run with NotInTask and unwinds" {
  let d = @driver.Driver::new()
  let other = @driver.Driver::new()
  let log = []
  let r = driver_error_kind(() => {
    d.run(() => {
      defer log.push("main unwound")
      other.sleep(5)
      log.push("unreachable")
    })
  })
  guard r is Ok(NotInTask) else { fail("got \{@debug.to_string(r)}") }
  assert_eq(log, ["main unwound"])
  assert_eq(d.live_tasks(), 0)
  assert_eq(other.pending_timers(), 0)
  assert_eq(other.live_tasks(), 0)
  // Both drivers still work.
  assert_eq(d.run(() => 1), 1)
  assert_eq(other.run(() => 2), 2)
}

///|
test "a nested driver's task parking on the outer driver fails the inner run" {
  let outer = @driver.Driver::new()
  let r = outer.run(() => {
    let inner = @driver.Driver::new()
    let kind = driver_error_kind(() => inner.run(() => outer.pause()))
    // The outer task carries on: it can still park on its own driver.
    outer.sleep(3)
    (kind, outer.now())
  })
  guard r is (Ok(NotInTask), 3L) else { fail("got \{@debug.to_string(r)}") }
}

///|
test "run called from a task of the same driver raises Reentrant" {
  let d = @driver.Driver::new()
  let r = d.run(() => driver_error_kind(() => d.run(() => 1)))
  guard r is Ok(Reentrant) else { fail("got \{@debug.to_string(r)}") }
}

///|
test "step called from a task of the same driver raises Reentrant" {
  let d = @driver.Driver::new()
  let r = d.run(() => driver_error_kind(() => d.step()))
  guard r is Ok(Reentrant) else { fail("got \{@debug.to_string(r)}") }
}

///|
test "a cancelled main task raises MainCancelled" {
  let d = @driver.Driver::new()
  let r = driver_error_kind(() => {
    d.run(() => {
      let main = d.current_task()
      let _ = d.spawn(() => {
        d.sleep(1)
        main.cancel()
      })
      d.sleep(10)
    })
  })
  guard r is Ok(MainCancelled) else { fail("got \{@debug.to_string(r)}") }
  assert_eq(d.now(), 1L)
}

///|
test "a failure that is waited on does not fail run" {
  let d = @driver.Driver::new()
  let r = d.run(() => {
    let t = d.spawn(() => {
      d.sleep(1)
      fail("observed")
    })
    try t.wait() catch {
      Failure(msg) => msg
      _ => "other"
    } noraise {
      _ => "completed"
    }
  })
  assert_true(r.contains("observed"))
}

///|
test "a waker is one-shot" {
  let d = @driver.Driver::new()
  let wakers : Array[@driver.Waker] = []
  let mut resumed = 0
  let mut ready_after_stale_wake = -1
  d.run(() => {
    let t = d.spawn(() => {
      d.park(w => wakers.push(w))
      resumed += 1
      d.park(w => wakers.push(w))
      resumed += 1
    })
    d.pause()
    wakers[0].wake()
    d.pause()
    // t has parked again: the first waker no longer resumes it.
    wakers[0].wake()
    ready_after_stale_wake = d.ready_tasks()
    assert_true(t.is_parked())
    wakers[1].wake()
    let _ = t.wait()
  })
  assert_eq(ready_after_stale_wake, 0)
  assert_eq(resumed, 2)
  assert_eq(wakers.length(), 2)
}

///|
test "cancel_and_join finishes cleanup before the caller's own cancellation" {
  let d = @driver.Driver::new()
  let log = []
  let parent_task : Ref[@driver.Task?] = Ref(None)
  let completed = d.run(() => {
    let parent = d.spawn(() => {
      defer log.push("parent unwound")
      let child = d.spawn(() => {
        defer {
          log.push("child unwound")
          // Cancels the caller while it is still joining.
          if parent_task.val is Some(p) {
            p.cancel()
          }
        }
        d.sleep(1000)
      })
      d.pause()
      d.cancel_and_join([child])
      log.push(
        "joined, cancel requested: \{d.current_task().is_cancel_requested()}",
      )
      // The masked cancellation is delivered at the next suspension.
      d.pause()
      log.push("not reached")
    })
    parent_task.val = Some(parent)
    parent.wait()
  })
  assert_false(completed)
  assert_eq(log, [
    "child unwound", "joined, cancel requested: true", "parent unwound",
  ])
  assert_eq(d.now(), 0L)
  assert_eq(d.live_tasks(), 0)
}

// ------------------------------------------------------------ bounds

///|
test "max_steps allows exactly that many steps per run" {
  let d = @driver.Driver::new(max_steps=10)
  // One start step plus 9 resumes: 10 steps, at the limit.
  let pauses = n => {
    d.run(() => {
      for _ in 0..<n {
        d.pause()
      }
    })
  }
  pauses(9)
  // The budget is per run: a second run gets 10 steps again.
  pauses(9)
  assert_eq(d.steps(), 20)
  // One past the limit.
  let r = driver_error_kind(() => pauses(10))
  guard r is Ok(NoQuiescence(steps~)) else {
    fail("got \{@debug.to_string(r)}")
  }
  assert_eq(steps, 11)
}

///|
/// A task whose `defer` spawns a replacement, `respawns` times in all.
fn respawning(d : @driver.Driver, respawns : Int32) -> Unit {
  let _ = d.spawn(() => {
    defer (if respawns > 0 { respawning(d, respawns - 1) })
    d.sleep(1_000_000)
  })
}

///|
test "unwinding gives up after max_unwind_rounds rounds" {
  assert_eq(@driver.max_unwind_rounds, 8)
  // 7 replacements: the last is cancelled in round 8.
  let d = @driver.Driver::new()
  assert_eq(
    d.run(() => {
      respawning(d, @driver.max_unwind_rounds - 1)
      "ok"
    }),
    "ok",
  )
  assert_eq(d.live_tasks(), 0)
  // 8 replacements: one is still alive after round 8.
  let d2 = @driver.Driver::new()
  let r = driver_error_kind(() => {
    d2.run(() => {
      respawning(d2, @driver.max_unwind_rounds)
      "ok"
    })
  })
  guard r is Ok(UnwindIncomplete(live~)) else {
    fail("got \{@debug.to_string(r)}")
  }
  assert_eq(live, 1)
  assert_eq(d2.live_tasks(), 1)
}

// ------------------------------------------------ manual control and state

///|
test "manual stepping with advance fires timers in arming order" {
  let d = @driver.Driver::new(auto_advance=false, start_ms=100L)
  let log = []
  let t = d.spawn(() => {
    d.sleep(5)
    log.push("woke @\{d.now()}")
  })
  let _ = d.add_timer(105L, () => log.push("first @105"))
  let cancelled = d.add_timer(105L, () => log.push("cancelled"))
  let _ = d.add_timer(104L, () => log.push("early @104"))
  cancelled.cancel()
  assert_eq(d.ready_tasks(), 1)
  assert_true(d.step())
  assert_true(t.is_parked())
  assert_eq(d.pending_timers(), 3)
  assert_false(d.step())
  d.advance(-3)
  assert_eq(d.now(), 100L)
  d.advance(5)
  assert_eq(d.now(), 105L)
  // A step fires every due timer first (earliest deadline first, equal
  // deadlines in arming order), then runs the oldest ready task: the
  // sleeper's timer only made it ready, so it logs after the actions.
  assert_true(d.step())
  assert_false(d.step())
  assert_eq(log, ["early @104", "first @105", "woke @105"])
  assert_true(t.is_done())
  assert_eq(d.pending_timers(), 0)
  assert_false(d.advance_to_next_timer())
}

///|
test "task state queries" {
  let d = @driver.Driver::new()
  let mut seen_by_waker : String = ""
  let (done, cancelled) = d.run(() => {
    let done = d.spawn(
      () => {
        d.park(w => {
          seen_by_waker = w.task().label()
          w.wake()
        })
      },
      label="done",
    )
    let cancelled = d.spawn(() => d.sleep(100), label="cancelled")
    d.sleep(1)
    assert_false(cancelled.is_cancel_requested())
    cancelled.cancel()
    assert_true(cancelled.is_cancel_requested())
    let _ = cancelled.wait()
    let _ = done.wait()
    (done, cancelled)
  })
  assert_eq(seen_by_waker, "done")
  assert_true(done.is_done())
  assert_true(done.is_finished())
  assert_false(done.is_cancelled())
  assert_true(cancelled.is_cancelled())
  assert_false(cancelled.is_done())
  // Cancelling a finished task changes nothing.
  done.cancel()
  assert_true(done.is_done())
  assert_false(done.is_cancel_requested())
}

///|
test "a failure while tasks unwind fails a run whose main succeeded" {
  let d = @driver.Driver::new()
  let r = driver_error_kind(() => {
    d.run(() => {
      let _ = d.spawn(() => {
        defer {
          let _ = d.spawn(() => fail("failed while unwinding"), label="late")
        }
        d.sleep(1000)
      })
      "main done"
    })
  })
  guard r is Ok(TaskFailed(label~, ..)) else {
    fail("got \{@debug.to_string(r)}")
  }
  assert_eq(label, "late")
  assert_eq(d.live_tasks(), 0)
}

// ------------------------------------------- waiters and foreign drivers

///|
test "a waiter cancelled before the failure does not hide it" {
  let d = @driver.Driver::new()
  let r = driver_error_kind(() => {
    d.run(() => {
      let target = d.spawn(
        () => {
          d.sleep(10)
          fail("target failed")
        },
        label="target",
      )
      let waiter = d.spawn(() => ignore(target.wait()))
      d.pause()
      d.cancel_and_join([waiter])
      d.sleep(20)
      "main finished"
    })
  })
  guard r is Ok(TaskFailed(label="target", ..)) else {
    fail("got \{@debug.to_string(r)}")
  }
}

///|
test "a waiter cancelled after the failure woke it does not observe it" {
  let d = @driver.Driver::new()
  let r = driver_error_kind(() => {
    d.run(() => {
      let target = d.spawn(
        () => {
          d.sleep(10)
          fail("target failed")
        },
        label="target",
      )
      let waiter = d.spawn(() => ignore(target.wait()))
      // Fires right after the target's timer, so it runs after the failure
      // has woken the waiter and before the waiter resumes.
      let _ = d.spawn(() => {
        d.sleep(10)
        waiter.cancel()
      })
      d.sleep(20)
      "main finished"
    })
  })
  guard r is Ok(TaskFailed(label="target", ..)) else {
    fail("got \{@debug.to_string(r)}")
  }
}

///|
test "one waiter that observes a failure covers the cancelled ones" {
  let d = @driver.Driver::new()
  let observed = d.run(() => {
    let target = d.spawn(() => {
      d.sleep(10)
      fail("target failed")
    })
    let cancelled = d.spawn(() => ignore(target.wait()))
    let observer = d.spawn(() => {
      let _ = target.wait() catch { _ => false }
    })
    let _ = d.spawn(() => {
      d.sleep(10)
      cancelled.cancel()
    })
    let _ = observer.wait()
    d.sleep(20)
    "main finished"
  })
  assert_eq(observed, "main finished")
}

///|
test "cancel_and_join from a nested driver's task fails the inner run without spinning" {
  let outer = @driver.Driver::new()
  let log = []
  let r = outer.run(() => {
    let child = outer.spawn(() => {
      defer log.push("child unwound")
      outer.sleep(1000)
    })
    outer.pause()
    let inner = @driver.Driver::new()
    let kind = driver_error_kind(() => {
      inner.run(() => outer.cancel_and_join([child]))
    })
    // The cancellation request still reached the child; the outer task
    // can join it itself.
    outer.cancel_and_join([child])
    (kind, outer.now())
  })
  guard r is (Ok(NotInTask), 0L) else { fail("got \{@debug.to_string(r)}") }
  assert_eq(log, ["child unwound"])
  assert_eq(outer.live_tasks(), 0)
}

///|
test "cancel_and_join on an idle driver from another driver's task reports NotInTask" {
  let d = @driver.Driver::new()
  let other = @driver.Driver::new()
  let log = []
  let task = other.spawn(() => {
    defer log.push("unwound")
    other.sleep(5)
  })
  let r = driver_error_kind(() => d.run(() => other.cancel_and_join([task])))
  guard r is Ok(NotInTask) else { fail("got \{@debug.to_string(r)}") }
  // Only the request was made; the task unwinds when its own driver runs.
  assert_true(task.is_cancel_requested())
  other.run(() => ())
  assert_eq(log, ["unwound"])
}

///|
test "a failure of a task joined only by cancel_and_join fails run" {
  let d = @driver.Driver::new()
  let r = driver_error_kind(() => {
    d.run(() => {
      // The child starts and fails before it reaches a cancellation point.
      let child = d.spawn(() => fail("child failed"), label="child")
      d.cancel_and_join([child])
      "main finished"
    })
  })
  guard r is Ok(TaskFailed(label="child", ..)) else {
    fail("got \{@debug.to_string(r)}")
  }
}

///|
test "a task that cancel_and_join ends by cancellation stays silent" {
  let d = @driver.Driver::new()
  let log = []
  let r = d.run(() => {
    let child = d.spawn(() => {
      defer log.push("child unwound")
      d.sleep(1000)
    })
    d.pause()
    d.cancel_and_join([child])
    child.is_cancelled()
  })
  assert_true(r)
  assert_eq(log, ["child unwound"])
}

///|
test "a failure seen by a waiter stays silent when cancel_and_join also joins" {
  let d = @driver.Driver::new()
  let seen = d.run(() => {
    let child = d.spawn(
      () => {
        // Parks, and fails rather than unwinding when it is cancelled.
        ignore(d.park_check_cancel(_ => ()))
        fail("child failed")
      },
      label="child",
    )
    let waiter = d.spawn(() => {
      let _ = child.wait() catch { _ => false }
    })
    d.pause()
    d.cancel_and_join([child])
    waiter.wait()
  })
  assert_true(seen)
}

// ------------------------------------------------------------ invariants
// One test per invariant stated in driver.mbt (O1–O4, B1–B5, C1–C3) where
// the tests above do not already pin it.

///|
/// Arms a timer due now that re-arms itself every time it fires, forever.
fn rearm_forever(d : @driver.Driver, fired : Ref[Int32]) -> Unit {
  let _ = d.add_timer(d.now(), () => {
    fired.val += 1
    rearm_forever(d, fired)
  })
}

///|
test "B2: a self-rearming due timer does not starve ready tasks" {
  let d = @driver.Driver::new(max_steps=100)
  let fired = Ref(0)
  let r = d.run(() => {
    rearm_forever(d, fired)
    for _ in 0..<5 {
      d.pause()
    }
    "main finished"
  })
  assert_eq(r, "main finished")
  // At most one firing per step.
  assert_true(fired.val <= d.steps())
  assert_eq(d.pending_timers(), 0)
}

///|
test "B3: a timer armed while unwinding does not stall the other cleanups" {
  let d = @driver.Driver::new(max_steps=50)
  let fired = Ref(0)
  let log = []
  let _ = d.run(() => {
    let _ = d.spawn(() => {
      defer rearm_forever(d, fired)
      d.sleep(1000)
    })
    for name in ["b", "c", "e"] {
      let _ = d.spawn(() => {
        defer log.push(name)
        d.sleep(1000)
      })
    }
    d.pause()
  })
  assert_eq(log, ["b", "c", "e"])
  assert_eq(d.live_tasks(), 0)
  assert_eq(d.pending_timers(), 0)
}

///|
test "O2: waiting on a task that already failed counts as seeing it" {
  let d = @driver.Driver::new()
  let seen = d.run(() => {
    let target = d.spawn(() => {
      d.sleep(10)
      fail("target failed")
    })
    let first = d.spawn(() => ignore(target.wait()))
    // Runs right after the target fails and before `first` resumes: it
    // sees the failure, then cancels `first`, which never does.
    let second = d.spawn(() => {
      d.sleep(10)
      let saw = target.wait() catch { _ => false }
      first.cancel()
      assert_false(saw)
    })
    second.wait()
  })
  assert_true(seen)
}

///|
test "O3: a waiter cancelled before the failure but resumed after is released once" {
  let d = @driver.Driver::new()
  let r = driver_error_kind(() => {
    d.run(() => {
      let waiter_task : Ref[@driver.Task?] = Ref(None)
      // Its timer is armed first, so it cancels the waiter just before the
      // target fails; the waiter resumes only after the failure.
      let _ = d.spawn(() => {
        d.sleep(10)
        if waiter_task.val is Some(w) {
          w.cancel()
        }
      })
      let target = d.spawn(
        () => {
          d.sleep(10)
          fail("target failed")
        },
        label="target",
      )
      waiter_task.val = Some(d.spawn(() => ignore(target.wait())))
      d.sleep(20)
      "main finished"
    })
  })
  guard r is Ok(TaskFailed(label="target", ..)) else {
    fail("got \{@debug.to_string(r)}")
  }
}

///|
test "C1: waiting on a task of another driver fails run with NotInTask" {
  let d = @driver.Driver::new()
  let other = @driver.Driver::new()
  let log = []
  let target = other.spawn(() => ())
  let r = driver_error_kind(() => {
    d.run(() => {
      defer log.push("main unwound")
      ignore(target.wait())
      log.push("not reached")
    })
  })
  guard r is Ok(NotInTask) else { fail("got \{@debug.to_string(r)}") }
  assert_eq(log, ["main unwound"])
  // The target is untouched and still runs on its own driver.
  other.run(() => ())
  assert_true(target.is_done())
}

///|
test "B4: a task is queued once however often it is woken or cancelled" {
  let d = @driver.Driver::new()
  let wakers : Array[@driver.Waker] = []
  let queued = d.run(() => {
    let t = d.spawn(() => d.park(w => wakers.push(w)))
    d.pause()
    wakers[0].wake()
    wakers[0].wake()
    t.cancel()
    t.cancel()
    let queued = d.ready_tasks()
    let _ = t.wait()
    queued
  })
  assert_eq(queued, 1)
}

///|
test "B2: a timer armed earlier than an older due one does not hide it" {
  let d = @driver.Driver::new(auto_advance=false, start_ms=10L)
  let log = []
  let _ = d.add_timer(0L, () => {
    log.push("t0")
    let _ = d.add_timer(0L, () => log.push("new"))
  })
  let _ = d.add_timer(1L, () => log.push("t1"))
  // Both timers armed before the step and due fire in it, before main runs;
  // the one armed by the first callback waits for the next step.
  d.run(() => log.push("main"))
  assert_eq(log, ["t0", "t1", "main"])
}

///|
/// A deterministic xorshift generator, so the property test needs no
/// randomness from the platform.
priv struct Xorshift {
  mut state : UInt32
}

///|
fn Xorshift::below(self : Xorshift, n : Int32) -> Int32 {
  let mut x = self.state
  x = x ^ (x << 13)
  x = x ^ (x >> 17)
  x = x ^ (x << 5)
  self.state = x
  (x % n.reinterpret_as_uint()).reinterpret_as_int()
}

///|
/// What a timer's callback does when it fires: arm timers with these
/// deadlines (they get the next ids, in order), then cancel one timer.
priv struct Plan {
  arms : Array[Int64]
  cancel : Int32?
}

///|
priv struct ModelTimer {
  id : Int32
  at : Int64
  mut cancelled : Bool
  mut fired : Bool
}

///|
/// The reference: a step fires, in (deadline, arming) order, the timers
/// armed before it that are due when it starts and not cancelled by then;
/// a timer armed during the step fires on a later step.
fn model_steps(
  plans : Array[Plan],
  initial : Array[Int64],
  start_ms : Int64,
  advances : Array[Int32],
) -> Array[Array[Int32]] {
  let timers : Array[ModelTimer] = []
  let arm = (at : Int64) => {
    timers.push({ id: timers.length(), at, cancelled: false, fired: false, })
  }
  for at in initial {
    arm(at)
  }
  let mut now = start_ms
  let steps = []
  for advance in advances {
    let due = timers.filter(t => !t.cancelled && !t.fired && t.at <= now)
    due.sort_by((a, b) => {
      if a.at == b.at {
        a.id - b.id
      } else {
        a.at.compare(b.at)
      }
    })
    let fired = []
    for t in due {
      if t.cancelled {
        continue
      }
      t.fired = true
      fired.push(t.id)
      if plans.get(t.id) is Some(plan) {
        for at in plan.arms {
          arm(at)
        }
        if plan.cancel is Some(id) && id < timers.length() {
          timers[id].cancelled = true
        }
      }
    }
    steps.push(fired)
    now = now + advance.to_int64()
  }
  steps
}

///|
/// The same scenario on a Driver, stepped by hand outside any run.
fn driver_steps(
  plans : Array[Plan],
  initial : Array[Int64],
  start_ms : Int64,
  advances : Array[Int32],
) -> Array[Array[Int32]] raise {
  let d = @driver.Driver::new(auto_advance=false, start_ms~)
  let handles : Array[@driver.TimerHandle] = []
  let fired : Array[Int32] = []
  fn arm(at : Int64) -> Unit {
    let id = handles.length()
    handles.push(
      d.add_timer(at, () => {
        fired.push(id)
        if plans.get(id) is Some(plan) {
          for next in plan.arms {
            arm(next)
          }
          if plan.cancel is Some(target) && target < handles.length() {
            handles[target].cancel()
          }
        }
      }),
    )
  }
  for at in initial {
    arm(at)
  }
  let steps = []
  for advance in advances {
    let _ = d.step()
    steps.push(fired.copy())
    fired.clear()
    d.advance(advance)
  }
  steps
}

///|
test "B2: per-step timer firing matches the reference model" {
  let rng = Xorshift::{ state: 0x9E3779B9, }
  for case_ in 0..<300 {
    let start_ms = rng.below(4).to_int64()
    let initial = Array::makei(rng.below(6), _ => rng.below(6).to_int64())
    let plans = Array::makei(40, _ => {
      let arms = Array::makei(rng.below(3), _ => rng.below(6).to_int64())
      let cancel = if rng.below(3) == 0 { Some(rng.below(40)) } else { None }
      Plan::{ arms, cancel, }
    })
    let advances = Array::makei(8, _ => rng.below(2))
    assert_eq(
      driver_steps(plans, initial, start_ms, advances),
      model_steps(plans, initial, start_ms, advances),
      msg="case \{case_}",
    )
  }
}

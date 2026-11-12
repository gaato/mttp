///|
async test "gate admits FIFO and removes cancelled queued callers" {
  let gate = @runtime.SemaphoreGate::new()
  let clock = @runtime.VirtualClock()
  let queued = Ref(0)
  let order : Array[Int32] = []
  gate.acquire()
  @async.with_task_group(group => {
    for i in 0..<3 {
      let task = group.spawn(
        () => {
          queued.val += 1
          gate.acquire()
          defer gate.release()
          order.push(i)
        },
        no_wait=true,
      )
      clock.settle(until=() => queued.val == i + 1)
      if i == 1 {
        task.cancel()
        task.wait() catch {
          @async.WaitedTaskAlreadyCancelled => ()
          error => raise error
        }
      }
    }
    gate.release()
    clock.settle(until=() => order.length() == 2)
  })
  assert_eq(order, [0, 2])
}

///|
async test "gate handoff survives cancellation until cleanup can be installed" {
  let gate = @runtime.SemaphoreGate::new()
  let clock = @runtime.VirtualClock()
  let started = Ref(false)
  let acquired = Ref(false)
  let cleaned = Ref(false)
  let returned = Ref(false)
  gate.acquire()
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      started.val = true
      gate.acquire()
      defer {
        gate.release()
        cleaned.val = true
      }
      acquired.val = true
      @async.pause()
      returned.val = true
    })
    clock.settle(until=() => started.val)
    gate.release()
    task.cancel()
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => raise error
    }
  })
  assert_true(acquired.val)
  assert_true(cleaned.val)
  assert_false(returned.val)
  gate.acquire()
  gate.release()
}

///|
async test "gate excess releases are capped and nonpositive capacity stays empty" {
  let gate = @runtime.SemaphoreGate::new(permits=2)
  for _ in 0..<4 {
    gate.release()
  }
  gate.acquire()
  gate.acquire()
  let entered = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      gate.acquire()
      entered.val = true
      gate.release()
    })
    @async.pause()
  })
  assert_false(entered.val)
  gate.release()
  gate.release()
  for capacity in [-1, 0] {
    let empty = @runtime.SemaphoreGate::new(permits=capacity)
    empty.release()
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        empty.acquire()
        entered.val = true
      })
      @async.pause()
    })
    assert_false(entered.val)
  }
}

///|
async test "core cancellation passes catch all and noraise and completes protected cleanup" {
  let clock = @runtime.VirtualClock()
  let caught = Ref(false)
  let returned = Ref(false)
  let cleaned = Ref(false)
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      defer @async.protect_from_cancel(() => {
        @async.pause()
        cleaned.val = true
      })
      let _ : Unit? = @runtime.with_timeout_opt(clock, 100, () => {
        clock.sleep(1000)
      }) catch {
        _ => {
          caught.val = true
          None
        }
      }
      returned.val = true
    })
    clock.settle(until=() => clock.pending().length() == 2)
    task.cancel()
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => raise error
    }
  })
  assert_false(caught.val)
  assert_false(returned.val)
  assert_true(cleaned.val)
  assert_eq(clock.pending(), [])
}

///|
async test "timer deadline before preparation cancels a port wait without acquiring" {
  let clock = @runtime.VirtualClock()
  let timer = @runtime.ClockTimer::new(clock~)
  let gate = @runtime.SemaphoreGate::new(permits=0)
  let prepared = Ref(false)
  let done = Ref(true)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      done.val = timer.within(10, () => {
        gate.acquire()
        prepared.val = true
      })
    })
    clock.settle(until=() => clock.pending().length() == 1)
    clock.advance(10)
  })
  assert_false(done.val)
  assert_false(prepared.val)
  assert_eq(clock.pending(), [])
}

///|
async test "timer expiry joins a consumer's protected cleanup before returning" {
  let clock = @runtime.VirtualClock()
  let timer = @runtime.ClockTimer::new(clock~)
  let cleaned = Ref(false)
  let done = Ref(true)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      done.val = timer.within(10, () => {
        defer (@async.protect_from_cancel(() => {
          @async.pause()
          cleaned.val = true
        }) catch {
          _ => ()
        })
        clock.sleep(1000)
      })
      assert_true(cleaned.val)
    })
    clock.settle(until=() => clock.pending().length() == 2)
    clock.advance(10)
  })
  assert_false(done.val)
  assert_true(cleaned.val)
  assert_eq(clock.pending(), [])
}

///|
async test "timer cancellation during release compensates exactly once" {
  let clock = @runtime.VirtualClock()
  let timer = @runtime.ClockTimer::new(clock~)
  let gate = @runtime.SemaphoreGate::new()
  let releases = Ref(0)
  let compensated = Ref(0)
  let held = Ref(false)
  let result = Ref(true)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      result.val = timer.within(10, () => {
        gate.acquire()
        held.val = true
        releases.val += 1
        // A remote release may suspend; compensate if the deadline cancels
        // that suspension before the release has committed.
        errdefer {
          gate.release()
          held.val = false
          compensated.val += 1
        }
        clock.sleep(1000)
        gate.release()
        held.val = false
      })
    })
    clock.settle(until=() => held.val && clock.pending().length() == 2)
    clock.advance(10)
  })
  assert_false(result.val)
  assert_false(held.val)
  assert_eq(releases.val, 1)
  assert_eq(compensated.val, 1)
  gate.acquire()
  gate.release()
}

///|
suberror CallbackMarker {
  CallbackMarker(Int32)
}

///|
async test "clock timeout helper preserves callback error identity and disarms deadline" {
  let clock = @runtime.VirtualClock()
  try {
    let _ : Unit? = @runtime.with_timeout_opt(clock, 10, () => {
      raise CallbackMarker(7)
    })
  } catch {
    CallbackMarker(7) => ()
    error => raise error
  } noraise {
    _ => fail("callback error lost")
  }
  assert_eq(clock.pending(), [])
  assert_eq(@runtime.with_timeout_opt(clock, 0, () => 7), Some(7))
  assert_eq(clock.pending(), [])
  let completed = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      assert_true(
        @runtime.ClockTimer::new(clock~).within(100, () => clock.sleep(1)),
      )
      completed.val = true
      assert_eq(clock.pending(), [])
    })
    clock.settle(until=() => clock.pending().length() == 2)
    clock.advance(1)
  })
  assert_true(completed.val)
}

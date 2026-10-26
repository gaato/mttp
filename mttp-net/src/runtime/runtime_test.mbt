///|
priv struct ControlledClock {
  started : @aqueue.Queue[Int32]
  wake : @cond_var.Cond
  mut pending : Int32
}

///|
fn ControlledClock::new() -> ControlledClock {
  {
    started: @aqueue.Queue(kind=Unbounded),
    wake: @cond_var.Cond(),
    pending: 0,
  }
}

///|
impl @clock.Clock for ControlledClock with fn now_unix_ms(_) {
  0L
}

///|
impl @clock.Clock for ControlledClock with fn sleep(self, ms) {
  if ms <= 0 {
    return
  }
  self.pending += 1
  defer {
    self.pending -= 1
  }
  self.started.put(ms) catch {
    _ => ()
  }
  self.wake.wait()
}

///|
async test "runtime timer cancels timed out work and removes its waiter" {
  let clock = ControlledClock::new()
  let timer : &@clock.Timer = @runtime.ClockTimer::new(clock~)
  let waiting : @aqueue.Queue[Int32] = @aqueue.Queue(kind=Unbounded)
  let outcome = Ref(None)
  let closed = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      outcome.val = Some(
        timer.within(10, () => {
          defer {
            closed.val = true
          }
          let _ = waiting.get() catch { _ => 0 }
        }),
      )
    })
    assert_eq(clock.started.get(), 10)
    clock.wake.signal()
  })
  assert_eq(outcome.val, Some(false))
  assert_true(closed.val)
  assert_eq(clock.pending, 0)
}

///|
async test "runtime timer completion and nonpositive budgets have no leftover task" {
  let clock = ControlledClock::new()
  let timer = @runtime.ClockTimer::new(clock~)
  let started = Ref(0)
  for ms in [0, -1] {
    assert_false(timer.within(ms, () => started.val += 1))
  }
  assert_eq(started.val, 0)
  assert_true(timer.within(10, () => started.val += 1))
  assert_eq(started.val, 1)
  assert_eq(clock.pending, 0)
  assert_eq(@runtime.with_timeout_opt(clock, 10, () => 7), Some(7))
  assert_eq(clock.pending, 0)
}

///|
async test "runtime timer preserves parent cancellation and unwinds the callback" {
  let clock = ControlledClock::new()
  let timer = @runtime.ClockTimer::new(clock~)
  let waiting : @aqueue.Queue[Int32] = @aqueue.Queue(kind=Unbounded)
  let finished = Ref(false)
  let closed = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      let _ = timer.within(10, () => {
        defer {
          closed.val = true
        }
        let _ = waiting.get() catch { _ => 0 }
      })
      finished.val = true
    })
    let _ = clock.started.get()
    group.return_immediately(())
  })
  assert_false(finished.val)
  assert_true(closed.val)
  assert_eq(clock.pending, 0)
}

///|
async test "semaphore gate bounds concurrent admission and cancelled waits do not take permits" {
  let gate : &@clock.Gate = @runtime.SemaphoreGate::new()
  gate.acquire()
  let entered = Ref(false)
  let ready : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      ready.put(())
      gate.acquire()
      entered.val = true
      gate.release()
    })
    ready.get()
    @async.pause()
    assert_false(entered.val)
    group.return_immediately(())
  })
  gate.release()
  gate.acquire()
  gate.release()
  assert_false(entered.val)
  let clamped = @runtime.SemaphoreGate::new(permits=0)
  clamped.acquire()
  clamped.release()
}

///|
async test "production clock yields for positive delays and reads wall time" {
  let clock = @runtime.AsyncClock::new()
  assert_true(clock.now_unix_ms() > 0L)
  clock.sleep(0)
  clock.sleep(1)
}

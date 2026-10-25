///|
priv struct ManualClock {
  mut now : Int64
  started : @aqueue.Queue[Int32]
  wake : @cond_var.Cond
  mut pending : Int32
}

///|
fn ManualClock::new(now~ : Int64 = 0L) -> ManualClock {
  {
    now,
    started: @aqueue.Queue(kind=Unbounded),
    wake: @cond_var.Cond(),
    pending: 0,
  }
}

///|
impl @clock.Clock for ManualClock with fn now_unix_ms(self) {
  self.now
}

///|
impl @clock.Clock for ManualClock with fn sleep(self, ms) {
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
async test "phase timeout cancels work and reports the limiting budget" {
  let limits = { total: 1000, pool: 100, connect: 200, write: 300, read: 400, }
  let rows : Array[(@model.Phase, Int32)] = [
    (Pool, 100),
    (Dial, 200),
    (Write, 300),
    (Head, 400),
    (Body, 400),
  ]
  for (phase, expected) in rows {
    let clock = ManualClock::new()
    let timer = PhaseTimer::exchange(clock, limits)
    let unwound = Ref(false)
    let stopped = Ref(false)
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        timer.run(phase, () => {
          defer {
            unwound.val = true
          }
          @cond_var.Cond().wait()
        }) catch {
          @model.TransportError(kind=Timeout(ms~), phase=actual, ..) => {
            assert_eq(ms, expected)
            assert_eq(actual, phase)
            stopped.val = true
          }
          error => raise error
        }
      })
      assert_eq(clock.started.get(), expected)
      clock.wake.signal()
    })
    assert_true(stopped.val && unwound.val)
    assert_eq(clock.pending, 0)
  }
  let clock = ManualClock::new()
  let timer = PhaseTimer::exchange(clock, limits)
  clock.now = 950L
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      try timer.run(Body, () => @cond_var.Cond().wait()) catch {
        @model.TransportError(kind=Timeout(ms=1000), phase=Body, ..) => ()
        error => raise error
      } noraise {
        _ => fail("expected total deadline")
      }
    })
    assert_eq(clock.started.get(), 50)
    clock.wake.signal()
  })
  clock.now = 1000L
  timer.run(Dial, () => fail("expired callback must not run")) catch {
    @model.TransportError(kind=Timeout(ms=1000), phase=Dial, ..) => ()
    error => raise error
  }
  assert_eq(PhaseTimer::stream(clock, limits).run(Body, () => 7), 7)
  assert_eq(clock.pending, 0)
}

///|
suberror Broken {
  Broken
}

///|
async test "phase mapping preserves typed failures and bounds extreme clocks" {
  let backend = H1Backend::new(
    trust_env=false,
    timeout_ms=10,
    pool_timeout_ms=1,
    connect_timeout_ms=2,
    write_timeout_ms=3,
    read_timeout_ms=4,
  )
  let phases : Array[@model.Phase] = [Pool, Dial, Write, Head, Body]
  assert_eq(phases.map(p => backend.limits.of(p)), [1, 2, 3, 4, 4])
  let clock = ManualClock::new(now=9223372036854775805L)
  let timer = PhaseTimer::exchange(clock, backend.limits)
  assert_eq(timer.deadline, Some(9223372036854775807L))
  clock.now = -10L
  for phase in [@model.Phase::Dial, Write, Body] {
    timer.run(phase, () => raise Broken) catch {
      @model.TransportError(kind~, phase=actual, ..) => {
        assert_eq(kind, if phase == Dial { Connect } else { Network })
        assert_eq(actual, phase)
      }
    }
  }
  for ms in [0, -1] {
    let timer = PhaseTimer::exchange(
      clock,
      H1Backend::new(trust_env=false, timeout_ms=ms).limits,
    )
    timer.run(Dial, () => fail("spent budget")) catch {
      @model.TransportError(kind=Timeout(..), ..) => ()
      error => raise error
    }
  }
  assert_eq(clock.pending, 0)
}

///|
async test "queued slot waits release on grant timeout refusal and parent cancellation" {
  for mode in 0..<4 {
    let clock = ManualClock::new()
    let timer = PhaseTimer::exchange(
      clock,
      H1Backend::new(trust_env=false).limits,
    )
    let slots = Slots::new(max_total=1)
    slots.acquire("a", timer)
    let acquired = Ref(false)
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        try slots.acquire("b", timer) catch {
          @model.TransportError(kind=Timeout(..) | Closed, phase=Pool, ..) => ()
          error => raise error
        } noraise {
          _ => {
            acquired.val = true
            slots.release("b")
          }
        }
      })
      ignore(clock.started.get())
      assert_eq(slots.waiting.length(), 1)
      match mode {
        0 => slots.release("a")
        1 => clock.wake.signal()
        2 => slots.refuse_waiting()
        _ => group.return_immediately(())
      }
    })
    if mode != 0 {
      slots.release("a")
    }
    assert_eq(acquired.val, mode == 0)
    assert_eq(slots.waiting.length(), 0)
    assert_eq(slots.in_use, 0)
    assert_eq(clock.pending, 0)
  }
}

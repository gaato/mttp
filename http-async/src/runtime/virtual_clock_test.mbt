///|
async test "virtual clock waits for an explicit observation across long unobserved work" {
  let clock = @runtime.VirtualClock(start_ms=10L)
  let finished = Ref(false)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      for _ in 0..<64 {
        @async.pause()
      }
      finished.val = true
    })
    clock.settle(until=() => finished.val, max_rounds=1000)
    assert_true(finished.val)
  })
  assert_eq(clock.now_unix_ms(), 10L)
}

///|
async test "virtual clock wakes equal deadlines in registration order" {
  let clock = @runtime.VirtualClock(start_ms=0L)
  let order : Array[Int32] = []
  @async.with_task_group(group => {
    for i in 0..<3 {
      group.spawn_bg(() => {
        clock.sleep(10)
        order.push(i)
      })
    }
    clock.settle(until=() => clock.pending().length() == 3)
    assert_eq(clock.pending(), [10, 10, 10])
    assert_eq(clock.next_deadline(), Some(10L))
    assert_true(clock.advance_to_next())
    clock.settle(until=() => order.length() == 3)
    assert_eq(order, [0, 1, 2])
  })
  assert_false(clock.advance_to_next())
  @async.with_task_group(group => {
    group.spawn_bg(() => clock.sleep(20))
    group.spawn_bg(() => clock.sleep(5))
    clock.settle(until=() => clock.pending().length() == 2)
    assert_eq(clock.pending(), [5, 20])
    clock.advance(20)
  })
}

///|
async test "virtual clock jumps do not invent intermediate execution" {
  let clock = @runtime.VirtualClock(start_ms=0L)
  let observed : Array[Int64] = []
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      clock.sleep(10)
      observed.push(clock.now_unix_ms())
      clock.sleep(10)
      observed.push(clock.now_unix_ms())
    })
    clock.settle(until=() => clock.next_deadline() == Some(10L))
    clock.advance(100)
    clock.settle(until=() => clock.next_deadline() == Some(110L))
    assert_eq(observed, [100L])
    assert_true(clock.advance_to_next())
    clock.settle(until=() => observed.length() == 2)
  })
  assert_eq(observed, [100L, 110L])
}

///|
async test "virtual clock cancelled sleeps are removed before the next advance" {
  let clock = @runtime.VirtualClock()
  let closed = Ref(false)
  @async.with_task_group(group => {
    let task = group.spawn(
      () => {
        defer {
          closed.val = true
        }
        clock.sleep(100)
      },
      no_wait=true,
    )
    clock.settle(until=() => clock.pending().length() == 1)
    task.cancel()
    clock.settle(until=() => closed.val)
    assert_eq(clock.pending(), [])
    assert_false(clock.advance_to_next())
  })
}

///|
async test "virtual clock observation budget and cancellation do not move time" {
  let clock = @runtime.VirtualClock(start_ms=0L)
  for budget in [-1, 0, 4] {
    try clock.settle(until=() => false, max_rounds=budget) catch {
      @runtime.NoQuiescence(rounds~) => assert_eq(rounds, budget.max(0))
    } noraise {
      _ => fail("unmet observation must exhaust its budget")
    }
  }
  clock.settle(until=() => true, max_rounds=0)
  let started = Ref(false)
  let ended = Ref(false)
  @async.with_task_group(group => {
    let task = group.spawn(
      () => {
        defer {
          ended.val = true
        }
        started.val = true
        clock.settle(until=() => false)
      },
      no_wait=true,
    )
    clock.settle(until=() => started.val)
    task.cancel()
    clock.settle(until=() => ended.val)
  })
  assert_eq(clock.now_unix_ms(), 0L)
}

///|
async test "virtual clock rejects backwards movement and saturates timer arithmetic" {
  let clock = @runtime.VirtualClock(start_ms=9223372036854775800L)
  clock.advance(-100)
  assert_eq(clock.now_unix_ms(), 9223372036854775800L)
  @async.with_task_group(group => {
    let finished = Ref(false)
    group.spawn_bg(() => {
      clock.sleep(100)
      finished.val = true
    })
    clock.settle(until=() => clock.pending().length() == 1)
    assert_eq(clock.next_deadline(), Some(9223372036854775807L))
    clock.advance(100)
    clock.settle(until=() => finished.val)
  })
  assert_eq(clock.now_unix_ms(), 9223372036854775807L)
  clock.sleep(0)
  clock.sleep(-1)
  assert_eq(clock.pending(), [])
}

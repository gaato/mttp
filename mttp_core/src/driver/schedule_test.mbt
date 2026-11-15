///|
/// Spawns a task that parks and, once woken, logs `name`; returns it with a
/// function that wakes it.
fn parked_logger(
  d : @driver.Driver,
  log : Array[String],
  name : String,
) -> (@driver.Task, () -> Unit) {
  let mut waker : @driver.Waker? = None
  let task = d.spawn(() => {
    d.park(w => waker = Some(w))
    log.push(name)
  })
  (task, () => if waker is Some(w) { w.wake() })
}

///|
/// Runs one schedule over three parked tasks: `x` is woken by an I/O event,
/// then `y` and `z` by the program itself. Returns the order they ran in.
fn io_then_internal(schedule? : @driver.Schedule) -> String raise {
  let d = @driver.Driver::new(schedule?)
  let log = []
  d.run(() => {
    let (x, wake_x) = parked_logger(d, log, "x")
    let (y, wake_y) = parked_logger(d, log, "y")
    let (z, wake_z) = parked_logger(d, log, "z")
    d.pause()
    @driver.io_event(wake_x)
    wake_y()
    wake_z()
    ignore(x.wait())
    ignore(y.wait())
    ignore(z.wait())
  })
  log.join("")
}

///|
test "without a schedule an I/O event keeps its FIFO place" {
  assert_eq(io_then_internal(), "xyz")
  assert_eq(io_then_internal(schedule=@driver.Schedule::replay([])), "xyz")
}

///|
test "a seeded schedule lets only I/O-event tasks be overtaken" {
  let seen : Map[String, Int32] = Map([])
  for seed in 0..<64 {
    let order = io_then_internal(schedule=@driver.Schedule::seeded(seed))
    seen[order] = seen.get(order).unwrap_or(0) + 1
  }
  // x's event may reach x after y and z ran, but z never overtakes y: the
  // program woke both, in that order.
  let orders = seen.keys().collect()
  orders.sort()
  assert_eq(orders, ["xyz", "yxz", "yzx"])
}

///|
test "the same seed takes the same choices" {
  let run = (seed : Int32) => {
    let schedule = @driver.Schedule::seeded(seed)
    let order = io_then_internal(schedule~)
    (order, schedule.choices())
  }
  for seed in 0..<16 {
    assert_eq(run(seed), run(seed))
  }
}

///|
test "a replay clamps its choices and continues in FIFO order" {
  // At most two candidates at each point: 7 means the last one.
  let schedule = @driver.Schedule::replay([7])
  assert_eq(io_then_internal(schedule~), "yxz")
  assert_eq(schedule.choices(), [1, 0])
  let negative = @driver.Schedule::replay([-1, 1])
  assert_eq(io_then_internal(schedule=negative), "xyz")
}

///|
test "cancelling a task an I/O event woke ends its delay" {
  let orders : Map[String, Unit] = Map([])
  for seed in 0..<64 {
    let d = @driver.Driver::new(schedule=@driver.Schedule::seeded(seed))
    let log = []
    d.run(() => {
      let (x, wake_x) = parked_logger(d, log, "x")
      let (y, wake_y) = parked_logger(d, log, "y")
      d.pause()
      @driver.io_event(wake_x)
      // The cancellation reaches x now, before y is woken.
      x.cancel()
      wake_y()
      ignore(x.wait())
      ignore(y.wait())
    })
    orders[log.join("")] = ()
  }
  // x unwinds without logging and y runs, under every seed.
  assert_eq(orders.keys().collect(), ["y"])
}

///|
/// Under `schedule`, three sleepers due at 10: `a` armed at 0, `b` and `c`
/// at 5 (in that order), and `d` due at 11. Returns the wake order.
fn same_deadline(schedule : @driver.Schedule) -> String raise {
  let d = @driver.Driver::new(schedule~)
  let log = []
  d.run(() => {
    let tasks = [
      d.spawn(() => {
        d.sleep(10)
        log.push("a")
      }),
      d.spawn(() => {
        d.sleep(5)
        log.push("<")
        d.sleep(5)
        log.push("b")
      }),
      d.spawn(() => {
        d.sleep(5)
        d.sleep(5)
        log.push("c")
      }),
      d.spawn(() => {
        d.sleep(11)
        log.push("d")
      }),
    ]
    for t in tasks {
      ignore(t.wait())
    }
  })
  log.join("")
}

///|
test "timers keep deadline and arming order under every schedule" {
  assert_eq(same_deadline(@driver.Schedule::replay([])), "<abcd")
  assert_eq(same_deadline(@driver.Schedule::replay([1])), "<abcd")
  for seed in 0..<64 {
    let schedule = @driver.Schedule::seeded(seed)
    // a was armed before b and c, even though they share its deadline;
    // d is due later. None of these timers is a decision point.
    assert_eq(same_deadline(schedule), "<abcd")
    assert_eq(schedule.choices(), [])
  }
}

///|
/// Wakes x through I/O at time 0 and y after manual time control.
fn io_then_advance(
  schedule : @driver.Schedule,
  advance : (@driver.Driver) -> Unit raise,
) -> String raise {
  let d = @driver.Driver::new(schedule~)
  let log = []
  d.run(() => {
    let (x, wake_x) = parked_logger(d, log, "x")
    let (y, wake_y) = parked_logger(d, log, "y")
    d.pause()
    assert_eq(d.now(), 0L)
    @driver.io_event(wake_x)
    advance(d)
    wake_y()
    ignore(x.wait())
    ignore(y.wait())
  })
  log.join("")
}

///|
test "manual time advances end I/O overtaking under every schedule" {
  let advances : Array[(@driver.Driver) -> Unit raise] = [
    d => d.advance(1),
    d => {
      ignore(d.add_timer(1L, () => ()))
      assert_true(d.advance_to_next_timer())
    },
  ]
  for advance in advances {
    let schedules = [
      @driver.Schedule::replay([1]),
      @driver.Schedule::replay([]),
      ..Array::makei(64, seed => @driver.Schedule::seeded(seed)),
    ]
    for schedule in schedules {
      assert_eq(io_then_advance(schedule, advance), "xy")
      assert_eq(schedule.choices(), [])
    }
  }
}

///|
test "manual time control without a time advance preserves I/O choices" {
  let controls : Array[(@driver.Driver) -> Unit raise] = [
    d => d.advance(0),
    d => d.advance(-1),
    d => assert_false(d.advance_to_next_timer()),
    d => {
      ignore(d.add_timer(0L, () => ()))
      assert_true(d.advance_to_next_timer())
    },
  ]
  for control in controls {
    assert_eq(io_then_advance(@driver.Schedule::replay([1]), control), "yx")
  }
}

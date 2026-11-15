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
test "timers due together but armed at different instants fire in either order" {
  assert_eq(same_deadline(@driver.Schedule::replay([])), "<abcd")
  let seen : Map[String, Unit] = Map([])
  for seed in 0..<64 {
    seen[same_deadline(@driver.Schedule::seeded(seed))] = ()
  }
  let orders = seen.keys().collect()
  orders.sort()
  // b and c were armed at one instant and keep their order; d is due later.
  assert_eq(orders, ["<abcd", "<bacd", "<bcad"])
}

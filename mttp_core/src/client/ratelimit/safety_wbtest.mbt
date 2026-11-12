///|
// WindowLimiter release has no suspension points, so cleanup completes even
// during cancellation. Unexpected failures are checked by the gate assertions.
async fn release_slot(limiter : WindowLimiter, bucket : String) -> Unit noraise {
  limiter.respond(bucket, status=0, headers=@mttp_core.Headers::empty()) catch {
    _ => ()
  }
}

///|
test "cancelled gate and reset waiters consume no global admission" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @sim.SimClock::new(d)
    let gate = @sim.SimGate::new(d)
    let limiter = WindowLimiter::new(clock, (_, _) => None, gate=() => gate, global={
      limit: 1,
      window_ms: 1000,
    })
    limiter.admit("a", global_exempt=true)
    let queued = d.spawn(() => limiter.admit("a", global_exempt=false))
    d.pause()
    assert_eq(gate.waiting(), 1)
    queued.cancel()
    assert_false(queued.wait())
    assert_eq(gate.waiting(), 0)
    limiter.respond(
      "a",
      status=429,
      headers=@mttp_core.Headers::of([("retry-after", "1")]),
    )
    let sleeping = d.spawn(() => limiter.admit("a", global_exempt=false))
    d.sleep(10)
    sleeping.cancel()
    assert_false(sleeping.wait())
    assert_eq(gate.available(), 1)
    limiter.admit("other", global_exempt=false)
    assert_eq(d.now(), 10L)
    release_slot(limiter, "other")
  })
}

///|
// This concrete release never suspends; exercise cleanup after handoff under
// cancellation even though the RateLimiter trait cannot express that fact.
#warnings("-cancellable_defer")
test "FIFO gate handoff cancellation lets cleanup release the slot" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @sim.SimClock::new(d)
    let gate = @sim.SimGate::new(d)
    let limiter = WindowLimiter::new(clock, (_, _) => None, gate=() => {
      return gate
    })
    limiter.admit("a", global_exempt=true)
    let acquired = Ref(false)
    let waiter = d.spawn(() => {
      limiter.admit("a", global_exempt=true)
      defer release_slot(limiter, "a")
      acquired.val = true
      d.pause()
    })
    d.pause()
    limiter.respond("a", status=0, headers=@mttp_core.Headers::empty())
    waiter.cancel()
    assert_false(waiter.wait())
    assert_true(acquired.val)
    assert_eq(gate.available(), 1)
    limiter.admit("a", global_exempt=true)
    limiter.respond("a", status=0, headers=@mttp_core.Headers::empty())
  })
}

///|
test "group FIFO survives a cancelled middle waiter and paces in order" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @sim.SimClock::new(d)
    let gate = @sim.SimGate::new(d)
    let limiter = WindowLimiter::new(clock, (_, _) => None, gate=() => gate, pace=_ => {
      group: "all",
      min_interval_ms: 20,
    })
    limiter.admit("first", global_exempt=false)
    let order = []
    let tasks = [
      for name in ["second", "cancel", "third"] => {
        d.spawn(() => {
          limiter.admit(name, global_exempt=false)
          order.push((name, d.now()))
          release_slot(limiter, name)
        })
      }
    ]
    d.pause()
    tasks[1].cancel()
    assert_false(tasks[1].wait())
    limiter.respond("first", status=0, headers=@mttp_core.Headers::empty())
    assert_true(tasks[0].wait())
    assert_true(tasks[2].wait())
    assert_eq(order, [("second", 20L), ("third", 40L)])
  })
}

///|
test "a global block learned during a gate wait is rechecked at admission" {
  let d = @driver.Driver::new()
  d.run(() => {
    let limiter = WindowLimiter::new(
      @sim.SimClock::new(d),
      (_, _) => None,
      gate=() => @sim.SimGate::new(d),
      scope=(_, _) => Global,
    )
    limiter.admit("a", global_exempt=false)
    let admitted = Ref(-1L)
    let task = d.spawn(() => {
      limiter.admit("a", global_exempt=false)
      admitted.val = d.now()
      release_slot(limiter, "a")
    })
    d.pause()
    limiter.respond(
      "a",
      status=429,
      headers=@mttp_core.Headers::of([("retry-after-ms", "50")]),
    )
    assert_true(task.wait())
    assert_eq(admitted.val, 50L)
  })
}

///|
test "bucket waits cannot reserve a global slot in an earlier window" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @sim.FakeClock::new()
    let limiter = WindowLimiter::new(clock, (_, _) => None, global={
      limit: 1,
      window_ms: 100,
    })
    limiter.respond(
      "a",
      status=429,
      headers=@mttp_core.Headers::of([("retry-after-ms", "200")]),
    )
    limiter.admit("a", global_exempt=false)
    limiter.admit("b", global_exempt=false)
    assert_eq(clock.slept(), [200, 100])
  })
}

///|
test "a Timer cancelling admission leaves bucket remaining and pace untouched" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @sim.SimClock::new(d)
    let limiter = WindowLimiter::new(
      clock,
      rate_limit_headers(remaining="remaining", reset_after_seconds="reset"),
      gate=() => @sim.SimGate::new(d),
      pace=_ => { group: "all", min_interval_ms: 100, },
    )
    limiter.admit("a", global_exempt=false)
    limiter.respond(
      "a",
      status=200,
      headers=@mttp_core.Headers::of([("remaining", "2"), ("reset", "1")]),
    )
    let timer = @sim.SimTimer::new(d)
    assert_false(
      timer.within(10, () => {
        limiter.admit("a", global_exempt=false) catch {
          _ => ()
        }
      }),
    )
    assert_eq(limiter.state("a").map(s => s.remaining), Some(2))
    limiter.admit("a", global_exempt=false)
    limiter.respond("a", status=0, headers=@mttp_core.Headers::empty())
    assert_eq(d.now(), 100L)
    assert_eq(limiter.state("a").map(s => s.remaining), Some(1))
    assert_eq(d.pending_timers(), 0)
  })
}

///|
test "Client uses rate_limit_bucket and global_exempt attributes" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @sim.SimClock::new(d)
    let limiter = WindowLimiter::new(clock, (_, _) => None, global={
      limit: 1,
      window_ms: 100,
    })
    limiter.respond(
      "write",
      status=429,
      headers=@mttp_core.Headers::of([("retry-after-ms", "20")]),
    )
    let client = @client.Client::new(
      @client.from_fn((_, _) => @mttp_core.Response::new(200)),
      clock,
      limiter~,
    )
    defer client.close()
    let _ = @client.get("https://example.test/")
      .attribute(@client.rate_limit_bucket, "write")
      .send(client)
    assert_eq(d.now(), 20L)
    let _ = @client.get("https://example.test/")
      .attribute(@client.global_exempt, true)
      .send(client)
    assert_eq(d.now(), 20L)
    let _ = @client.get("https://example.test/").send(client)
    assert_eq(d.now(), 120L)
  })
}

///|
fn quota(left : String, reset : String) -> @mttp.Headers {
  @mttp.Headers::of([("left", left), ("reset", reset)])
}

///|
fn reconciler(clock : &@rt.Clock) -> WindowLimiter {
  WindowLimiter::new(
    clock,
    rate_limit_headers(remaining="left", reset_unix_seconds="reset"),
    server_key=(_, headers) => headers.get("key"),
  )
}

///|
test "shorter concurrent 429s cannot shorten an active bucket block" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    limiter.respond(
      "a",
      status=429,
      headers=quota("0", "1").set("retry-after-ms", "1500"),
    )
    limiter.respond(
      "a",
      status=429,
      headers=quota("0", "1").set("retry-after-ms", "500"),
    )
    limiter.admit("a", global_exempt=false)
    assert_eq(clock.slept(), [1500])
    limiter.respond("a", status=0, headers=@mttp.Headers::empty())
  })
}

///|
test "a bucket 429 without a delay preserves positive parsed quota" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    limiter.respond("a", status=429, headers=quota("2", "1"))
    limiter.admit("a", global_exempt=false)
    assert_eq(clock.slept(), [])
    limiter.respond("a", status=0, headers=@mttp.Headers::empty())
  })
}

///|
test "a delayed success cannot undo a concurrent Retry-After block" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    limiter.admit("a", global_exempt=false)
    limiter.admit("a", global_exempt=false)
    limiter.respond(
      "a",
      status=429,
      headers=quota("0", "1").set("retry-after-ms", "1500"),
    )
    limiter.respond("a", status=200, headers=quota("5", "1"))
    limiter.admit("a", global_exempt=false)
    assert_eq(clock.slept(), [1500])
    limiter.respond("a", status=0, headers=@mttp.Headers::empty())
  })
}

///|
test "out-of-order successes cannot replenish a consumed window" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    let older = limiter.acquire("a", global_exempt=false)
    let newer = limiter.acquire("a", global_exempt=false)
    limiter.release(newer, status=200, headers=quota("2", "1"))
    let third = limiter.acquire("a", global_exempt=false)
    limiter.release(older, status=200, headers=quota("5", "1"))
    assert_eq(limiter.state("a").map(s => s.remaining), Some(1))
    limiter.release(third, status=0, headers=@mttp.Headers::empty())
    limiter.admit("a", global_exempt=false)
    limiter.respond("a", status=0, headers=@mttp.Headers::empty())
    limiter.admit("a", global_exempt=false)
    assert_eq(clock.slept(), [1000])
    limiter.respond("a", status=0, headers=@mttp.Headers::empty())
  })
}

///|
test "exact response attribution removes conservative completed-admission debt" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    limiter.admit("a", global_exempt=false)
    limiter.admit("a", global_exempt=false)
    limiter.respond("a", status=0, headers=@mttp.Headers::empty())
    limiter.admit("a", global_exempt=false)
    limiter.respond("a", status=0, headers=@mttp.Headers::empty())
    limiter.respond("a", status=200, headers=quota("3", "1"))
    assert_eq(limiter.state("a").map(s => s.remaining), Some(3))
  })
}

///|
test "an older admission cannot replace quota even with a later reset" {
  @driver.run_sync(() => {
    let limiter = reconciler(@sim.FakeClock::new())
    let older = limiter.acquire("a", global_exempt=false)
    let newer = limiter.acquire("a", global_exempt=false)
    limiter.release(newer, status=200, headers=quota("4", "2"))
    assert_eq(
      limiter.state("a"),
      Some({ remaining: 4, reset_at_unix_ms: 2000L, }),
    )
    limiter.release(older, status=200, headers=quota("8", "1"))
    assert_eq(
      limiter.state("a"),
      Some({ remaining: 4, reset_at_unix_ms: 2000L, }),
    )
  })
}

///|
test "a newer quota window retains an active block without losing its quota" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    limiter.respond(
      "a",
      status=429,
      headers=quota("0", "1").set("retry-after-ms", "1500"),
    )
    limiter.respond("a", status=200, headers=quota("4", "2"))
    limiter.admit("a", global_exempt=false)
    assert_eq(clock.slept(), [1500])
    assert_eq(limiter.state("a").map(s => s.remaining), Some(3))
    limiter.respond("a", status=0, headers=@mttp.Headers::empty())
  })
}

///|
test "a response older than shared local consumption cannot replenish it" {
  @driver.run_sync(() => {
    let limiter = reconciler(@sim.FakeClock::new())
    for bucket in ["a", "b"] {
      limiter.respond(
        bucket,
        status=200,
        headers=quota("10", "1").set("key", "shared"),
      )
    }
    let older = limiter.acquire("a", global_exempt=false)
    let newer = limiter.acquire("b", global_exempt=false)
    limiter.release(newer, status=200, headers=quota("1", "1"))
    limiter.release(older, status=200, headers=quota("3", "2"))
    assert_eq(limiter.state("b").map(s => s.remaining), Some(1))
  })
}

///|
test "live aliases survive quota expiry and a forced capacity sweep" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    for bucket in ["a", "b"] {
      limiter.respond(
        bucket,
        status=200,
        headers=quota("1", "1").set("key", "shared"),
      )
    }
    for i in 0..<4094 {
      limiter.respond("other-\{i}", status=200, headers=quota("1", "1"))
    }
    clock.advance(1000)
    limiter.respond("trigger", status=200, headers=quota("1", "2"))
    limiter.respond(
      "a",
      status=200,
      headers=quota("0", "2").set("key", "shared"),
    )
    limiter.admit("b", global_exempt=false)
    assert_eq(clock.slept(), [1000])
    limiter.respond("b", status=0, headers=@mttp.Headers::empty())
  })
}

///|
fn quota(left : String, reset : String) -> @http.Headers {
  @http.Headers::of([("left", left), ("reset", reset)])
}

///|
fn reconciler(clock : &@rt.Clock) -> @ratelimit.WindowLimiter {
  @ratelimit.WindowLimiter::new(
    clock,
    @ratelimit.rate_limit_headers(remaining="left", reset_unix_seconds="reset"),
    server_key=(_, headers) => headers.get("key"),
  )
}

///|
test "shorter concurrent 429s cannot shorten an active bucket block" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    limiter.release(
      "a",
      status=429,
      headers=quota("0", "1").set("retry-after-ms", "1500"),
    )
    limiter.release(
      "a",
      status=429,
      headers=quota("0", "1").set("retry-after-ms", "500"),
    )
    limiter.acquire("a", global_exempt=false)
    assert_eq(clock.slept(), [1500])
    limiter.release("a", status=0, headers=@http.Headers::empty())
  })
}

///|
test "a bucket 429 without a delay preserves positive parsed quota" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    limiter.release("a", status=429, headers=quota("2", "1"))
    limiter.acquire("a", global_exempt=false)
    assert_eq(clock.slept(), [])
    limiter.release("a", status=0, headers=@http.Headers::empty())
  })
}

///|
test "a delayed success cannot undo a concurrent Retry-After block" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    limiter.acquire("a", global_exempt=false)
    limiter.acquire("a", global_exempt=false)
    limiter.release(
      "a",
      status=429,
      headers=quota("0", "1").set("retry-after-ms", "1500"),
    )
    limiter.release("a", status=200, headers=quota("5", "1"))
    limiter.acquire("a", global_exempt=false)
    assert_eq(clock.slept(), [1500])
    limiter.release("a", status=0, headers=@http.Headers::empty())
  })
}

///|
test "out-of-order successes cannot replenish a consumed window" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    limiter.acquire("a", global_exempt=false)
    limiter.acquire("a", global_exempt=false)
    limiter.release("a", status=200, headers=quota("2", "1"))
    limiter.acquire("a", global_exempt=false)
    limiter.release("a", status=200, headers=quota("5", "1"))
    assert_eq(limiter.state("a").map(s => s.remaining), Some(0))
    limiter.release("a", status=0, headers=@http.Headers::empty())
    limiter.acquire("a", global_exempt=false)
    assert_eq(clock.slept(), [1000])
    limiter.release("a", status=0, headers=@http.Headers::empty())
  })
}

///|
test "a first response accounts for later admissions including completed ones" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    limiter.acquire("a", global_exempt=false)
    limiter.acquire("a", global_exempt=false)
    limiter.release("a", status=0, headers=@http.Headers::empty())
    limiter.acquire("a", global_exempt=false)
    limiter.release("a", status=0, headers=@http.Headers::empty())
    limiter.release("a", status=200, headers=quota("3", "1"))
    assert_eq(limiter.state("a").map(s => s.remaining), Some(1))
  })
}

///|
test "a newer reset replaces quota and an older response cannot replace it" {
  @driver.run_sync(() => {
    let limiter = reconciler(@sim.FakeClock::new())
    limiter.release("a", status=200, headers=quota("0", "1"))
    limiter.release("a", status=200, headers=quota("4", "2"))
    assert_eq(
      limiter.state("a"),
      Some({ remaining: 4, reset_at_unix_ms: 2000L, }),
    )
    limiter.release("a", status=200, headers=quota("8", "1"))
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
    limiter.release(
      "a",
      status=429,
      headers=quota("0", "1").set("retry-after-ms", "1500"),
    )
    limiter.release("a", status=200, headers=quota("4", "2"))
    limiter.acquire("a", global_exempt=false)
    assert_eq(clock.slept(), [1500])
    assert_eq(limiter.state("a").map(s => s.remaining), Some(3))
    limiter.release("a", status=0, headers=@http.Headers::empty())
  })
}

///|
test "overlapping shared buckets account for later admissions" {
  @driver.run_sync(() => {
    let limiter = reconciler(@sim.FakeClock::new())
    for bucket in ["a", "b"] {
      limiter.release(
        bucket,
        status=200,
        headers=quota("10", "1").set("key", "shared"),
      )
    }
    limiter.acquire("a", global_exempt=false)
    limiter.acquire("b", global_exempt=false)
    limiter.release("b", status=0, headers=@http.Headers::empty())
    limiter.release("a", status=200, headers=quota("3", "2"))
    assert_eq(limiter.state("b").map(s => s.remaining), Some(2))
  })
}

///|
test "live aliases survive quota expiry and a forced capacity sweep" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    for bucket in ["a", "b"] {
      limiter.release(
        bucket,
        status=200,
        headers=quota("1", "1").set("key", "shared"),
      )
    }
    for i in 0..<4094 {
      limiter.release("other-\{i}", status=200, headers=quota("1", "1"))
    }
    clock.advance(1000)
    limiter.release("trigger", status=200, headers=quota("1", "2"))
    limiter.release(
      "a",
      status=200,
      headers=quota("0", "2").set("key", "shared"),
    )
    limiter.acquire("b", global_exempt=false)
    assert_eq(clock.slept(), [1000])
    limiter.release("b", status=0, headers=@http.Headers::empty())
  })
}

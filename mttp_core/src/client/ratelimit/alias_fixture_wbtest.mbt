///|
test "Retry-After overrides an existing quota deadline in the same window" {
  @driver.run_sync(() => {
    for delayed_success in [false, true] {
      let clock = @sim.FakeClock::new()
      let limiter = reconciler(clock)
      limiter.respond("a", status=200, headers=quota("5", "60"))
      limiter.respond(
        "a",
        status=429,
        headers=quota("5", "60").set("retry-after", "1"),
      )
      if delayed_success {
        limiter.respond("a", status=200, headers=quota("5", "60"))
      }
      assert_eq(
        limiter.state("a"),
        Some({ remaining: 0, reset_at_unix_ms: 1000L, }),
      )
      limiter.admit("a", global_exempt=false)
      assert_eq(clock.slept(), [1000])
      limiter.respond("a", status=0, headers=@mttp_core.Headers::empty())
    }
  })
}

///|
test "learning changing and removing an alias preserve an active block" {
  @driver.run_sync(() => {
    for old in ["a", "old"] {
      for next in ["shared", "a"] {
        for reset in ["1", "2"] {
          let clock = @sim.FakeClock::new()
          let limiter = reconciler(clock)
          limiter.admit("a", global_exempt=false)
          limiter.admit("a", global_exempt=false)
          if old != "a" {
            limiter.respond(
              "a",
              status=200,
              headers=quota("5", "1").set("key", old),
            )
            limiter.admit("a", global_exempt=false)
          }
          limiter.respond(
            "a",
            status=429,
            headers=quota("0", "1").set("retry-after-ms", "1500"),
          )
          limiter.respond(
            "a",
            status=200,
            headers=quota("5", reset).set("key", next),
          )
          limiter.admit("a", global_exempt=false)
          assert_eq(clock.slept(), [1500])
          limiter.respond("a", status=0, headers=@mttp_core.Headers::empty())
        }
      }
    }
  })
}

///|
test "alias transitions preserve lower quota with and without parsed headers" {
  @driver.run_sync(() => {
    for old in ["a", "old"] {
      for next in ["shared", "a"] {
        for parsed in [false, true] {
          let clock = @sim.FakeClock::new()
          let limiter = reconciler(clock)
          let older = limiter.acquire("a", global_exempt=false)
          let newer = limiter.acquire("a", global_exempt=false)
          limiter.release(
            newer,
            status=200,
            headers=quota("2", "60").set("key", old),
          )
          let consumed = limiter.acquire("a", global_exempt=false)
          limiter.release(
            older,
            status=200,
            headers=if parsed {
              quota("9", "60").set("key", next)
            } else {
              @mttp_core.Headers::of([("key", next)])
            },
          )
          assert_eq(limiter.state("a").map(s => s.remaining), Some(1))
          limiter.release(
            consumed,
            status=0,
            headers=@mttp_core.Headers::empty(),
          )
        }
      }
    }
  })
}

///|
test "an alias merge preserves constraints at both source and destination" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    limiter.respond("a", status=200, headers=quota("3", "60"))
    let delayed = limiter.acquire("a", global_exempt=false)
    limiter.respond(
      "peer",
      status=200,
      headers=quota("1", "60").set("key", "shared"),
    )
    limiter.release(
      delayed,
      status=200,
      headers=quota("9", "60").set("key", "shared"),
    )
    assert_eq(limiter.state("a").map(s => s.remaining), Some(1))
    limiter.admit("a", global_exempt=false)
    limiter.respond("a", status=0, headers=@mttp_core.Headers::empty())
    assert_eq(limiter.state("peer").map(s => s.remaining), Some(0))
  })
}

///|
test "a stale destination Retry-After cannot expire live transferred quota" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = reconciler(clock)
    limiter.respond("a", status=200, headers=quota("1", "60"))
    limiter.respond(
      "shared",
      status=429,
      headers=quota("0", "60").set("retry-after", "1"),
    )
    clock.advance(2000)
    limiter.respond(
      "a",
      status=200,
      headers=@mttp_core.Headers::of([("key", "shared")]),
    )
    assert_eq(
      limiter.state("a"),
      Some({ remaining: 1, reset_at_unix_ms: 60000L, }),
    )
    limiter.admit("a", global_exempt=false)
    limiter.respond("a", status=0, headers=@mttp_core.Headers::empty())
    limiter.admit("a", global_exempt=false)
    assert_eq(clock.slept(), [58000])
    limiter.respond("a", status=0, headers=@mttp_core.Headers::empty())
  })
}

///|
fn alias_limiter(clock : &@rt.Clock) -> WindowLimiter {
  WindowLimiter::new(
    clock,
    rate_limit_headers(remaining="left", reset_unix_seconds="reset"),
    server_key=(_, headers) => headers.get("key"),
  )
}

///|
fn alias_quota(left : String, reset : String) -> @http.Headers {
  @http.Headers::of([("left", left), ("reset", reset)])
}

///|
test "alias expiry transfers a refreshed shared block and quota before detaching" {
  @driver.run_sync(() => {
    for sweep in [false, true] {
      for blocked in [false, true] {
        let clock = @sim.FakeClock::new()
        let limiter = alias_limiter(clock)
        limiter.release(
          "a",
          status=200,
          headers=alias_quota("5", "1").set("key", "shared"),
        )
        clock.advance(3_599_000)
        limiter.release(
          "shared",
          status=if blocked { 429 } else { 200 },
          headers=if blocked {
            alias_quota("0", "3601").set("retry-after", "2")
          } else {
            alias_quota("1", "3601")
          },
        )
        clock.advance(1000)
        if sweep {
          limiter.sweep_states(limiter.now(), force=true)
        }
        assert_eq(
          limiter.state("a").map(s => s.remaining),
          Some(if blocked { 0 } else { 1 }),
        )
        assert_false(limiter.aliases.contains("a"))
        limiter.acquire("a", global_exempt=false)
        assert_eq(clock.slept(), if blocked { [1000] } else { [] })
        limiter.release("a", status=0, headers=@http.Headers::empty())
      }
    }
  })
}

///|
test "alias expiry at state capacity retains its route until transfer has room" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = alias_limiter(clock)
    limiter.release(
      "a",
      status=200,
      headers=alias_quota("5", "1").set("key", "shared"),
    )
    clock.advance(3_599_000)
    limiter.release(
      "shared",
      status=429,
      headers=alias_quota("0", "3601").set("retry-after", "2"),
    )
    for i in 0..<4095 {
      limiter.release(
        "filler-\{i}",
        status=200,
        headers=alias_quota("1", "3601"),
      )
    }
    clock.advance(1000)
    limiter.sweep_states(limiter.now(), force=true)
    assert_eq(limiter.states.length(), 4096)
    assert_eq(limiter.resolve("a", limiter.now()), "shared")
    assert_eq(limiter.state("a").map(s => s.remaining), Some(0))
    // A vacated slot permits the deferred transfer without losing the block.
    limiter.states.remove("filler-0")
    assert_eq(limiter.resolve("a", limiter.now()), "a")
    assert_false(limiter.aliases.contains("a"))
    assert_eq(limiter.states.length(), 4096)
    limiter.acquire("a", global_exempt=false)
    assert_eq(clock.slept(), [1000])
    limiter.release("a", status=0, headers=@http.Headers::empty())
  })
}

///|
test "refused alias transitions preserve the previously resolved block" {
  @driver.run_sync(() => {
    for full_states in [false, true] {
      let clock = @sim.FakeClock::new()
      let limiter = alias_limiter(clock)
      limiter.release(
        "a",
        status=429,
        headers=alias_quota("0", "60").set("retry-after", "1"),
      )
      if full_states {
        for i in 0..<4095 {
          limiter.release(
            "filler-\{i}",
            status=200,
            headers=alias_quota("5", "60"),
          )
        }
      } else {
        for i in 0..<4096 {
          limiter.release(
            "filler-\{i}",
            status=200,
            headers=alias_quota("5", "60").set("key", "shared"),
          )
        }
      }
      try
        limiter.release(
          "a",
          status=200,
          headers=@http.Headers::of([("key", "new")]),
        )
      catch {
        @http.TransportError(kind=TooLarge(limit=4096), phase=Unknown, ..) => ()
        _ => fail("wrong refusal")
      } noraise {
        _ => fail("accepted a transition without room")
      }
      assert_eq(limiter.resolve("a", limiter.now()), "a")
      limiter.acquire("a", global_exempt=false)
      assert_eq(clock.slept(), [1000])
      limiter.release("a", status=0, headers=@http.Headers::empty())
    }
  })
}

///|
test "admission accounting cannot allocate fallback state after capacity checks" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = alias_limiter(clock)
    limiter.release(
      "b",
      status=200,
      headers=alias_quota("5", "1").set("key", "shared"),
    )
    limiter.acquire("b", global_exempt=false)
    clock.advance(3_599_000)
    limiter.release("shared", status=200, headers=alias_quota("5", "3601"))
    for i in 0..<4094 {
      limiter.release(
        "filler-\{i}",
        status=200,
        headers=alias_quota("1", "3601"),
      )
    }
    clock.advance(1000)
    // Exercise the lazy path without a threshold or periodic sweep. Resolving
    // b during admission-debt accounting would consume the last state slot
    // after a's insertion had already passed its capacity check.
    limiter.states_sweep_at = 20_000
    limiter.states_swept_at_ms = limiter.now()
    limiter.release("a", status=200, headers=alias_quota("1", "3601"))
    assert_eq(limiter.states.length(), 4096)
    assert_eq(limiter.resolve("b", limiter.now()), "shared")
    assert_eq(limiter.states.length(), 4096)
    limiter.release("b", status=0, headers=@http.Headers::empty())
    assert_eq(limiter.admissions.length(), 0)
  })
}

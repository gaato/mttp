///|
fn ordered(
  clock : &@rt.Clock,
  relative~ : Bool = false,
) -> @ratelimit.WindowLimiter {
  @ratelimit.WindowLimiter::new(
    clock,
    @ratelimit.rate_limit_headers(
      remaining="left",
      reset_after_seconds=if relative { "reset" } else { "unused" },
      reset_unix_seconds="reset",
    ),
    server_key=(_, h) => h.get("key"),
  )
}

///|
fn head(left : String, reset : String) -> @mttp_core.Headers {
  @mttp_core.Headers::of([("left", left), ("reset", reset)])
}

///|
test "relative reset delivery drift cannot replenish an overlapping response" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = ordered(clock, relative=true)
    let older = limiter.acquire("a", global_exempt=false)
    let newer = limiter.acquire("a", global_exempt=false)
    assert_true(older.sequence() < newer.sequence())
    assert_eq(newer.bucket(), "a")
    limiter.release(newer, status=200, headers=head("0", "1"))
    clock.advance(100)
    limiter.release(older, status=200, headers=head("5", "1"))
    assert_eq(limiter.state("a").map(s => s.remaining), Some(0))
  })
}

///|
test "a quota-free 429 overrides an existing ordinary reset deadline" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = ordered(clock)
    let first = limiter.acquire("a", global_exempt=false)
    let second = limiter.acquire("a", global_exempt=false)
    limiter.release(first, status=200, headers=head("0", "60"))
    limiter.release(
      second,
      status=429,
      headers=@mttp_core.Headers::of([("retry-after", "1")]),
    )
    assert_eq(
      limiter.state("a"),
      Some({ remaining: 0, reset_at_unix_ms: 1000L, }),
    )
    let next = limiter.acquire("a", global_exempt=false)
    assert_eq(clock.slept(), [1000])
    limiter.release(next, status=0, headers=@mttp_core.Headers::empty())
  })
}

///|
test "admission sequence permits refresh independently of reset timestamp ordering" {
  @driver.run_sync(() => {
    for later_date in [false, true] {
      let limiter = ordered(@sim.FakeClock::new())
      let older = limiter.acquire("a", global_exempt=false)
      let newer = limiter.acquire("a", global_exempt=false)
      limiter.release(older, status=200, headers=head("0", "60"))
      limiter.release(
        newer,
        status=200,
        headers=head("5", if later_date { "120" } else { "1" }),
      )
      assert_eq(limiter.state("a").map(s => s.remaining), Some(5))
    }
  })
}

///|
test "duplicate and mismatched releases cannot change state aliases or a new gate holder" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @sim.FakeClock::new()
    let gate = @sim.SimGate::new(d)
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      @ratelimit.rate_limit_headers(
        remaining="left",
        reset_unix_seconds="reset",
      ),
      gate=() => gate,
      server_key=(_, h) => h.get("key"),
    )
    let first = limiter.acquire("a", global_exempt=false)
    limiter.release(first, status=200, headers=head("2", "60"))
    let second = limiter.acquire("a", global_exempt=false)
    assert_true(second.sequence() > first.sequence())
    let malicious = head("0", "60")
      .set("retry-after", "3600")
      .set("key", "wrong")
    limiter.release(first, status=429, headers=malicious)
    limiter.release(
      @client.Admission::new("other", sequence=second.sequence()),
      status=429,
      headers=malicious,
    )
    assert_eq(gate.available(), 0)
    assert_eq(limiter.state("a").map(s => s.remaining), Some(1))
    assert_eq(limiter.state("wrong"), None)
    limiter.release(second, status=0, headers=@mttp_core.Headers::empty())
    assert_eq(gate.available(), 1)
    limiter.release(second, status=200, headers=malicious)
    assert_eq(gate.available(), 1)
    assert_eq(limiter.state("a").map(s => s.remaining), Some(1))
  })
}

///|
test "NoLimiter issues increasing opaque admissions and ignores repeated release" {
  @driver.run_sync(() => {
    let limiter = @client.NoLimiter::new()
    let first = limiter.acquire("a", global_exempt=false)
    let second = limiter.acquire("b", global_exempt=true)
    assert_eq(first.bucket(), "a")
    assert_eq(second.bucket(), "b")
    assert_true(second.sequence() > first.sequence())
    for _ in 0..<2 {
      limiter.release(first, status=0, headers=@mttp_core.Headers::empty())
    }
    limiter.release(second, status=200, headers=@mttp_core.Headers::empty())
  })
}

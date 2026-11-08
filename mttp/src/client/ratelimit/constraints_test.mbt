///|
test "an alias merge preserves ordinary exhaustion alongside a shorter Retry-After" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = ordered(clock)
    let naming = limiter.acquire("a", global_exempt=false)
    let blocked = limiter.acquire("a", global_exempt=false)
    let exhausted = limiter.acquire("shared", global_exempt=false)
    limiter.release(exhausted, status=200, headers=head("0", "60"))
    limiter.release(
      blocked,
      status=429,
      headers=@http.Headers::of([("retry-after", "1")]),
    )
    limiter.release(
      naming,
      status=200,
      headers=@http.Headers::of([("key", "shared")]),
    )
    assert_eq(
      limiter.state("a"),
      Some({ remaining: 0, reset_at_unix_ms: 60000L, }),
    )
    let next = limiter.acquire("a", global_exempt=false)
    assert_eq(clock.slept(), [60000])
    limiter.release(next, status=0, headers=@http.Headers::empty())
  })
}

///|
test "a stale Retry-After cannot discard a newer quota constraint on the same key" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = ordered(clock)
    let older = limiter.acquire("a", global_exempt=false)
    let newer = limiter.acquire("a", global_exempt=false)
    limiter.release(newer, status=200, headers=head("0", "60"))
    limiter.release(
      older,
      status=429,
      headers=@http.Headers::of([("retry-after", "1")]),
    )
    let next = limiter.acquire("a", global_exempt=false)
    assert_eq(clock.slept(), [60000])
    limiter.release(next, status=0, headers=@http.Headers::empty())
  })
}

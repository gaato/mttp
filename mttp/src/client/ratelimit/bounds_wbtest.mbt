///|
test "state maps accept 4096 live entries and refuse the next until eviction" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = WindowLimiter::new(clock, (_, now) => {
      Some({ remaining: 0, reset_at_unix_ms: now + 1000L, })
    })
    for i in 0..<4096 {
      limiter.release("b\{i}", status=200, headers=@http.Headers::empty())
    }
    assert_eq(limiter.states.length(), 4096)
    try
      limiter.release("overflow", status=200, headers=@http.Headers::empty())
    catch {
      @http.TransportError(kind=TooLarge(limit=4096), phase=Unknown, ..) => ()
      _ => fail("wrong capacity error")
    } noraise {
      _ => fail("accepted overflow")
    }
    assert_eq(limiter.states.length(), 4096)
    // Updating an existing key remains possible at capacity.
    limiter.release("b0", status=200, headers=@http.Headers::empty())
    clock.advance(1000)
    limiter.release("after", status=200, headers=@http.Headers::empty())
    assert_eq(limiter.states.length(), 1)
  })
}

///|
test "aliases expire even while their shared server window keeps refreshing" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = WindowLimiter::new(
      clock,
      (_, now) => Some({ remaining: 1, reset_at_unix_ms: now + 3_600_000L, }),
      server_key=(_, _) => Some("shared"),
    )
    for i in 0..<4096 {
      limiter.release("b\{i}", status=200, headers=@http.Headers::empty())
    }
    assert_eq(limiter.aliases.length(), 4096)
    try
      limiter.release("overflow", status=200, headers=@http.Headers::empty())
    catch {
      @http.TransportError(kind=TooLarge(limit=4096), ..) => ()
      _ => fail("wrong alias capacity error")
    } noraise {
      _ => fail("accepted alias overflow")
    }
    clock.advance(3_599_999)
    limiter.release("b0", status=200, headers=@http.Headers::empty())
    clock.advance(1)
    limiter.release("new", status=200, headers=@http.Headers::empty())
    assert_eq(limiter.aliases.length(), 2)
    assert_eq(limiter.states.length(), 1)
  })
}

///|
test "pace deadlines and active group gates refuse a 4097th live key" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @sim.FakeClock::new()
    for gated in [false, true] {
      let limiter = if gated {
        WindowLimiter::new(clock, (_, _) => None, gate=() => {
          @sim.SimGate::new(d)
        })
      } else {
        WindowLimiter::new(clock, (_, _) => None, pace=group => {
          group,
          min_interval_ms: 1000,
        })
      }
      for i in 0..<4096 {
        limiter.acquire("b\{i}", global_exempt=false)
      }
      try limiter.acquire("overflow", global_exempt=false) catch {
        @http.TransportError(kind=TooLarge(limit=4096), ..) => ()
        _ => fail("wrong admission capacity error")
      } noraise {
        _ => fail("accepted admission overflow")
      }
      for i in 0..<4096 {
        limiter.release("b\{i}", status=0, headers=@http.Headers::empty())
      }
      if gated {
        assert_eq(limiter.gates.length(), 0)
      }
      clock.advance(1000)
      limiter.acquire("after", global_exempt=false)
      limiter.release("after", status=0, headers=@http.Headers::empty())
    }
  })
}

///|
test "a recording failure releases the held gate and preserves other state" {
  let d = @driver.Driver::new()
  d.run(() => {
    let gate = @sim.SimGate::new(d)
    let limiter = WindowLimiter::new(
      @sim.FakeClock::new(),
      (_, now) => Some({ remaining: 0, reset_at_unix_ms: now + 1000L, }),
      gate=() => gate,
    )
    for i in 0..<4096 {
      limiter.release("b\{i}", status=200, headers=@http.Headers::empty())
    }
    limiter.acquire("overflow", global_exempt=false)
    limiter.release("overflow", status=200, headers=@http.Headers::empty()) catch {
      _ => ()
    }
    assert_eq(gate.available(), 1)
    assert_eq(limiter.gates.length(), 0)
    assert_eq(limiter.state("overflow"), None)
  })
}

///|
test "fallback server waits are capped at exactly one hour" {
  @driver.run_sync(() => {
    for scope in [Bucket, Global] {
      let clock = @sim.FakeClock::new()
      let limiter = WindowLimiter::new(
        clock,
        (_, _) => None,
        scope=(_, _) => scope,
        default_retry_after_ms=3_600_001,
      )
      limiter.release("a", status=429, headers=@http.Headers::empty())
      limiter.acquire("a", global_exempt=false)
      assert_eq(clock.slept(), [3_600_000])
    }
  })
}

///|
test "ignored responses cannot remap a bucket or consume alias space" {
  @driver.run_sync(() => {
    let limiter = WindowLimiter::new(
      @sim.FakeClock::new(),
      (_, now) => Some({ remaining: 1, reset_at_unix_ms: now + 1000L, }),
      server_key=(_, _) => Some("other"),
      scope=(_, _) => Ignore,
    )
    limiter.release("a", status=429, headers=@http.Headers::empty())
    assert_eq(limiter.aliases.length(), 0)
    assert_eq(limiter.states.length(), 0)
  })
}

///|
test "backward wall steps preserve relative bucket global and pace waits" {
  @driver.run_sync(() => {
    for kind in [0, 1, 2] {
      let clock = @sim.FakeClock::new(start_unix_ms=1000L)
      let limiter = match kind {
        0 => WindowLimiter::new(clock, (_, _) => None)
        1 =>
          WindowLimiter::new(clock, (_, _) => None, global={
            limit: 1,
            window_ms: 100,
          })
        _ =>
          WindowLimiter::new(clock, (_, _) => None, pace=group => {
            group,
            min_interval_ms: 100,
          })
      }
      if kind == 0 {
        limiter.release(
          "a",
          status=429,
          headers=@http.Headers::of([("retry-after-ms", "100")]),
        )
      } else {
        limiter.acquire("a", global_exempt=false)
      }
      clock.advance(-10_000)
      limiter.acquire("a", global_exempt=false)
      assert_eq(clock.slept(), [100])
    }
  })
}

///|
test "the elapsed clock saturates a wall delta that cannot fit in Int64" {
  let clock = ParkingClock::new(@driver.Driver::new(), -9223372036854775808L)
  let limiter = WindowLimiter::new(clock, (_, _) => None)
  clock.now = 9223372036854775807L
  assert_eq(limiter.now(), -1L)
  assert_eq(limiter.now(), -1L)
}

///|
priv struct AdjustableClock {
  driver : @driver.Driver
  offset : Ref[Int64]
}

///|
impl @rt.Clock for AdjustableClock with fn now_unix_ms(self) {
  self.driver.now() + self.offset.val
}

///|
impl @rt.Clock for AdjustableClock with fn sleep(self, ms) {
  self.driver.sleep(ms)
}

///|
test "overlapping sleeps across wall rollback advance elapsed time only once" {
  let d = @driver.Driver::new()
  d.run(() => {
    let offset = Ref(0L)
    let clock = AdjustableClock::{ driver: d, offset, }
    let limiter = WindowLimiter::new(clock, (_, _) => None)
    let tasks = []
    for bucket in ["a", "b", "c"] {
      limiter.release(
        bucket,
        status=429,
        headers=@http.Headers::of([("retry-after-ms", "100")]),
      )
      tasks.push(d.spawn(() => limiter.acquire(bucket, global_exempt=false)))
    }
    d.sleep(50)
    offset.val = -10_000L
    for task in tasks {
      assert_true(task.wait())
    }
    assert_eq(d.now(), 100L)
    assert_eq(limiter.now(), 100L)
  })
}

///|
test "a server key without reset headers still aliases an existing shared window" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = WindowLimiter::new(
      clock,
      rate_limit_headers(remaining="left", reset_after_seconds="reset"),
      server_key=(_, headers) => headers.get("key"),
    )
    limiter.release(
      "first",
      status=200,
      headers=@http.Headers::of([
        ("key", "shared"),
        ("left", "0"),
        ("reset", "1"),
      ]),
    )
    limiter.release(
      "second",
      status=200,
      headers=@http.Headers::of([("key", "shared")]),
    )
    limiter.acquire("second", global_exempt=false)
    assert_eq(clock.slept(), [1000])
  })
}

///|
test "admission cohorts are bounded and every release outcome reclaims them" {
  @driver.run_sync(() => {
    let limiter = WindowLimiter::new(@sim.FakeClock::new(), (_, _) => None, scope=(
      _,
      _,
    ) => Ignore)
    for i in 0..<4096 {
      limiter.acquire("b\{i}", global_exempt=false)
    }
    try limiter.acquire("overflow", global_exempt=false) catch {
      @http.TransportError(kind=TooLarge(limit=4096), phase=Pool, ..) => ()
      _ => fail("wrong admission capacity error")
    } noraise {
      _ => fail("accepted admission overflow")
    }
    assert_eq(limiter.admissions.length(), 4096)
    // Existing buckets need only a counter, not another map entry.
    limiter.acquire("b0", global_exempt=false)
    limiter.release("b0", status=429, headers=@http.Headers::empty())
    assert_eq(limiter.admissions.length(), 4096)
    for i in 0..<4096 {
      limiter.release("b\{i}", status=0, headers=@http.Headers::empty())
    }
    assert_eq(limiter.admissions.length(), 0)
    limiter.acquire("after", global_exempt=false)
    limiter.release("after", status=200, headers=@http.Headers::empty())
    assert_eq(limiter.admissions.length(), 0)
  })
}

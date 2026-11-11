///|
test "state maps accept 4096 live entries and refuse the next until eviction" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    let limiter = WindowLimiter::new(clock, (_, now) => {
      Some({ remaining: 0, reset_at_unix_ms: now + 1000L, })
    })
    for i in 0..<4096 {
      limiter.respond("b\{i}", status=200, headers=@mttp.Headers::empty())
    }
    assert_eq(limiter.states.length(), 4096)
    try
      limiter.respond("overflow", status=200, headers=@mttp.Headers::empty())
    catch {
      @mttp.TransportError(kind=TooLarge(limit=4096), phase=Unknown, ..) => ()
      _ => fail("wrong capacity error")
    } noraise {
      _ => fail("accepted overflow")
    }
    assert_eq(limiter.states.length(), 4096)
    // Updating an existing key remains possible at capacity.
    limiter.respond("b0", status=200, headers=@mttp.Headers::empty())
    clock.advance(1000)
    limiter.respond("after", status=200, headers=@mttp.Headers::empty())
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
      limiter.respond("b\{i}", status=200, headers=@mttp.Headers::empty())
    }
    assert_eq(limiter.aliases.length(), 4096)
    try
      limiter.respond("overflow", status=200, headers=@mttp.Headers::empty())
    catch {
      @mttp.TransportError(kind=TooLarge(limit=4096), ..) => ()
      _ => fail("wrong alias capacity error")
    } noraise {
      _ => fail("accepted alias overflow")
    }
    clock.advance(3_599_999)
    limiter.respond("b0", status=200, headers=@mttp.Headers::empty())
    clock.advance(1)
    limiter.respond("new", status=200, headers=@mttp.Headers::empty())
    assert_eq(limiter.aliases.length(), 2)
    // Expired aliases detach with the live shared quota as their fallback.
    assert_eq(limiter.states.length(), 4096)
    assert_eq(limiter.state("b1").map(s => s.remaining), Some(1))
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
        limiter.admit("b\{i}", global_exempt=false)
      }
      try limiter.admit("overflow", global_exempt=false) catch {
        @mttp.TransportError(kind=TooLarge(limit=4096), ..) => ()
        _ => fail("wrong admission capacity error")
      } noraise {
        _ => fail("accepted admission overflow")
      }
      for i in 0..<4096 {
        limiter.respond("b\{i}", status=0, headers=@mttp.Headers::empty())
      }
      if gated {
        assert_eq(limiter.gates.length(), 0)
      }
      clock.advance(1000)
      limiter.admit("after", global_exempt=false)
      limiter.respond("after", status=0, headers=@mttp.Headers::empty())
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
      limiter.respond("b\{i}", status=200, headers=@mttp.Headers::empty())
    }
    let refused = limiter.acquire("overflow", global_exempt=false)
    limiter.release(refused, status=200, headers=@mttp.Headers::empty()) catch {
      _ => ()
    }
    assert_eq(gate.available(), 1)
    assert_eq(limiter.gates.length(), 0)
    assert_eq(limiter.state("overflow"), None)
    let next = limiter.acquire("overflow", global_exempt=false)
    limiter.release(
      refused,
      status=429,
      headers=@mttp.Headers::of([("retry-after", "60")]),
    )
    assert_eq(gate.available(), 0)
    assert_eq(limiter.admissions.length(), 1)
    limiter.release(next, status=0, headers=@mttp.Headers::empty())
    assert_eq(gate.available(), 1)
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
      limiter.respond("a", status=429, headers=@mttp.Headers::empty())
      limiter.admit("a", global_exempt=false)
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
    limiter.respond("a", status=429, headers=@mttp.Headers::empty())
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
        limiter.respond(
          "a",
          status=429,
          headers=@mttp.Headers::of([("retry-after-ms", "100")]),
        )
      } else {
        limiter.admit("a", global_exempt=false)
      }
      clock.advance(-10_000)
      limiter.admit("a", global_exempt=false)
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
      limiter.respond(
        bucket,
        status=429,
        headers=@mttp.Headers::of([("retry-after-ms", "100")]),
      )
      tasks.push(d.spawn(() => limiter.admit(bucket, global_exempt=false)))
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
    limiter.respond(
      "first",
      status=200,
      headers=@mttp.Headers::of([
        ("key", "shared"),
        ("left", "0"),
        ("reset", "1"),
      ]),
    )
    limiter.respond(
      "second",
      status=200,
      headers=@mttp.Headers::of([("key", "shared")]),
    )
    limiter.admit("second", global_exempt=false)
    assert_eq(clock.slept(), [1000])
  })
}

///|
test "outstanding tokens are bounded and every release outcome reclaims them" {
  @driver.run_sync(() => {
    let limiter = WindowLimiter::new(@sim.FakeClock::new(), (_, _) => None, scope=(
      _,
      _,
    ) => Ignore)
    for i in 0..<4096 {
      limiter.admit("b\{i}", global_exempt=false)
    }
    try limiter.admit("overflow", global_exempt=false) catch {
      @mttp.TransportError(kind=TooLarge(limit=4096), phase=Pool, ..) => ()
      _ => fail("wrong admission capacity error")
    } noraise {
      _ => fail("accepted admission overflow")
    }
    assert_eq(limiter.admissions.length(), 4096)
    // Each request needs an identity, including requests for existing buckets.
    try limiter.admit("b0", global_exempt=false) catch {
      @mttp.TransportError(kind=TooLarge(limit=4096), phase=Pool, ..) => ()
      _ => fail("wrong token capacity error")
    } noraise {
      _ => fail("accepted an extra token for an existing bucket")
    }
    limiter.respond("b0", status=429, headers=@mttp.Headers::empty())
    assert_eq(limiter.admissions.length(), 4095)
    limiter.admit("b0", global_exempt=false)
    for i in 0..<4096 {
      limiter.respond("b\{i}", status=0, headers=@mttp.Headers::empty())
    }
    assert_eq(limiter.admissions.length(), 0)
    limiter.admit("after", global_exempt=false)
    limiter.respond("after", status=200, headers=@mttp.Headers::empty())
    assert_eq(limiter.admissions.length(), 0)
  })
}

///|
test "sequence exhaustion refuses before quota and releases the acquired gate" {
  let d = @driver.Driver::new()
  d.run(() => {
    let gate = @sim.SimGate::new(d)
    let limiter = WindowLimiter::new(
      @sim.FakeClock::new(),
      (_, now) => Some({ remaining: 2, reset_at_unix_ms: now + 1000L, }),
      gate=() => gate,
      global={ limit: 2, window_ms: 1000, },
    )
    let first = limiter.acquire("a", global_exempt=false)
    limiter.release(first, status=200, headers=@mttp.Headers::empty())
    limiter.sequence = 9223372036854775807L
    try limiter.acquire("a", global_exempt=false) catch {
      @mttp.TransportError(kind=Invalid, phase=Pool, ..) => ()
      _ => fail("wrong sequence exhaustion error")
    } noraise {
      _ => fail("sequence wrapped")
    }
    assert_eq(gate.available(), 1)
    assert_eq(limiter.state("a").map(s => s.remaining), Some(2))
    assert_eq(limiter.global_count, 1)
    assert_eq(limiter.admissions.length(), 0)
    assert_eq(limiter.gates.length(), 0)
  })
}

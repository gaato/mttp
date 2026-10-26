///|
test "WindowLimiter sleeps to reset and removes the expired state" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new(start_unix_ms=1000L)
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      @ratelimit.rate_limit_headers(
        remaining="remaining",
        reset_after_seconds="reset-after",
      ),
    )
    limiter.release(
      "bucket",
      status=200,
      headers=@model.Headers::of([("remaining", "0"), ("reset-after", "2")]),
    )
    limiter.acquire("bucket", global_exempt=false)
    assert_eq(clock.slept(), [2000])
    assert_eq(clock.now_unix_ms(), 3000L)
    assert_eq(limiter.state("bucket"), None)
  })
}

///|
test "WindowLimiter gives 429 Retry-After precedence" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new(start_unix_ms=1000L)
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      @ratelimit.rate_limit_headers(
        remaining="remaining",
        reset_after_seconds="reset-after",
      ),
    )
    limiter.release(
      "bucket",
      status=429,
      headers=@model.Headers::of([
        ("remaining", "5"),
        ("reset-after", "100"),
        ("retry-after", "1.5"),
      ]),
    )
    assert_eq(
      limiter.state("bucket"),
      Some({ remaining: 0, reset_at_unix_ms: 2500L, }),
    )
    limiter.acquire("bucket", global_exempt=false)
    assert_eq(clock.slept(), [1500])
    assert_eq(limiter.state("bucket"), None)
  })
}

///|
test "WindowLimiter buckets are independent and remaining is consumed" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new(start_unix_ms=1000L)
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      @ratelimit.rate_limit_headers(
        remaining="remaining",
        reset_after_seconds="reset-after",
      ),
    )
    limiter.release(
      "blocked",
      status=200,
      headers=@model.Headers::of([("remaining", "0"), ("reset-after", "2")]),
    )
    limiter.release(
      "open",
      status=200,
      headers=@model.Headers::of([("remaining", "2"), ("reset-after", "5")]),
    )
    limiter.acquire("open", global_exempt=false)
    assert_eq(clock.slept(), [])
    assert_eq(
      limiter.state("open"),
      Some({ remaining: 1, reset_at_unix_ms: 6000L, }),
    )
    assert_eq(
      limiter.state("blocked"),
      Some({ remaining: 0, reset_at_unix_ms: 3000L, }),
    )
    limiter.acquire("blocked", global_exempt=false)
    assert_eq(clock.slept(), [2000])
    assert_eq(
      limiter.state("open"),
      Some({ remaining: 1, reset_at_unix_ms: 6000L, }),
    )
  })
}

///|
test "WindowLimiter ignores a release without a response" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new(start_unix_ms=1000L)
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      @ratelimit.rate_limit_headers(
        remaining="remaining",
        reset_after_seconds="reset-after",
      ),
    )
    limiter.release(
      "bucket",
      status=200,
      headers=@model.Headers::of([("remaining", "3"), ("reset-after", "5")]),
    )
    limiter.release("bucket", status=0, headers=@model.Headers::empty())
    assert_eq(
      limiter.state("bucket"),
      Some({ remaining: 3, reset_at_unix_ms: 6000L, }),
    )
    limiter.acquire("bucket", global_exempt=true)
    assert_eq(clock.slept(), [])
    assert_eq(
      limiter.state("bucket"),
      Some({ remaining: 2, reset_at_unix_ms: 6000L, }),
    )
  })
}

///|
test "gates serialize one bucket and status zero preserves its state" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new()
    let made = Ref(0)
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      (_, now) => Some({ remaining: 3, reset_at_unix_ms: now + 1000L, }),
      gate=() => {
        made.val += 1
        @fake.SimGate::new(d)
      },
    )
    limiter.acquire("a", global_exempt=false)
    let entered = Ref(false)
    with_group(d, group => {
      let waiter = group.spawn(() => {
        limiter.acquire("a", global_exempt=false)
        entered.val = true
        limiter.release("a", status=0, headers=@model.Headers::empty())
      })
      d.sleep(10)
      assert_false(entered.val)
      limiter.acquire("b", global_exempt=false)
      limiter.release("b", status=200, headers=@model.Headers::empty())
      let state = limiter.state("b")
      limiter.acquire("b", global_exempt=false)
      let consumed = limiter.state("b")
      assert_true(state != consumed)
      limiter.release("b", status=0, headers=@model.Headers::empty())
      assert_eq(limiter.state("b"), consumed)
      limiter.acquire("b", global_exempt=false)
      limiter.release("b", status=0, headers=@model.Headers::empty())
      limiter.release("a", status=0, headers=@model.Headers::empty())
      assert_true(waiter.wait())
      assert_true(entered.val)
    })
    // The waiter on "a" reuses the holder's gate; "b" is idle between its three
    // acquires, so each one starts with a fresh gate.
    assert_eq(made.val, 4)
  })
}

///|
test "cancellation during a bucket reset returns the gate" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.SimClock::new(d)
    let gate = @fake.SimGate::new(d)
    let limiter = @ratelimit.WindowLimiter::new(clock, (_, _) => None, gate=() => {
      return gate
    })
    limiter.acquire("a", global_exempt=false)
    limiter.release(
      "a",
      status=429,
      headers=@model.Headers::of([("retry-after", "0.08")]),
    )
    with_group(d, group => {
      let waiter = group.spawn(allow_failure=true, () => {
        limiter.acquire("a", global_exempt=false)
      })
      d.sleep(10)
      waiter.cancel()
      assert_false(waiter.wait())
      // The parser does not clear the reset: the next caller must finish it.
      limiter.acquire("a", global_exempt=false)
      limiter.release("a", status=0, headers=@model.Headers::empty())
    })
  })
}

///|
test "global window starts at first admission and exempts bypass it" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new(start_unix_ms=123L)
    let limiter = @ratelimit.WindowLimiter::new(clock, (_, _) => None, global={
      limit: 2,
      window_ms: 1000,
    })
    limiter.acquire("a", global_exempt=true)
    clock.advance(100)
    limiter.acquire("a", global_exempt=false)
    limiter.acquire("b", global_exempt=false)
    limiter.acquire("c", global_exempt=true)
    assert_eq(clock.slept(), [])
    limiter.acquire("c", global_exempt=false)
    assert_eq(clock.slept(), [1000])
    assert_eq(clock.now_unix_ms(), 1223L)
    limiter.acquire("d", global_exempt=false)
    assert_eq(clock.slept(), [1000])
    let account = @ratelimit.WindowLimiter::new(
      clock,
      (_, _) => None,
      default_retry_after_ms=1000,
      global_block=_ => true,
    )
    account.release("a", status=429, headers=@model.Headers::empty())
    assert_eq(account.state("a"), None)
    account.acquire("b", global_exempt=true)
    assert_eq(clock.slept(), [1000])
    account.acquire("b", global_exempt=false)
    assert_eq(clock.slept(), [1000, 1000])
    let immediate = @ratelimit.WindowLimiter::new(
      clock,
      (_, _) => None,
      default_retry_after_ms=-1,
    )
    immediate.release("a", status=429, headers=@model.Headers::empty())
    assert_eq(
      immediate.state("a"),
      Some({ remaining: 0, reset_at_unix_ms: clock.now_unix_ms(), }),
    )
    immediate.acquire("a", global_exempt=false)
    assert_eq(clock.slept(), [1000, 1000])
  })
}

///|
test "global 429 preserves parsed bucket state and never shortens a block" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new(start_unix_ms=1000L)
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      (_, now) => Some({ remaining: 4, reset_at_unix_ms: now + 9000L, }),
      global_block=headers => headers.get("global") == Some("true"),
    )
    limiter.release(
      "a",
      status=429,
      headers=@model.Headers::of([("global", "true"), ("retry-after", "2")]),
    )
    limiter.release(
      "a",
      status=429,
      headers=@model.Headers::of([("global", "true"), ("retry-after", "1")]),
    )
    assert_eq(
      limiter.state("a"),
      Some({ remaining: 4, reset_at_unix_ms: 10000L, }),
    )
    limiter.acquire("b", global_exempt=true)
    assert_eq(clock.slept(), [])
    limiter.acquire("b", global_exempt=false)
    assert_eq(clock.slept(), [2000])
  })
}

///|
test "429 fallback is optional and applies only to the selected scope" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new()
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      (_, _) => None,
      default_retry_after_ms=1000,
      global_block=_ => false,
    )
    limiter.release("a", status=429, headers=@model.Headers::empty())
    limiter.acquire("b", global_exempt=false)
    assert_eq(clock.slept(), [])
    limiter.acquire("a", global_exempt=true)
    assert_eq(clock.slept(), [1000])
    let legacy = @ratelimit.WindowLimiter::new(clock, (_, _) => None)
    legacy.release("a", status=429, headers=@model.Headers::empty())
    legacy.acquire("a", global_exempt=false)
    assert_eq(legacy.state("a"), None)
    assert_eq(clock.slept(), [1000])
  })
}

///|
/// Paces `write:*` buckets as one group, one second apart; every other bucket
/// is its own unpaced group.
fn write_pace(bucket : String) -> @ratelimit.Pace {
  if bucket.has_prefix("write:") {
    { group: "write", min_interval_ms: 1000, }
  } else {
    { group: bucket, min_interval_ms: 0, }
  }
}

///|
fn limit_headers(pairs : Array[(String, String)]) -> @model.Headers {
  @model.Headers::of(pairs)
}

///|
test "pacing spaces one group's admissions and leaves other groups alone" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new(start_unix_ms=1000L)
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      (_, _) => None,
      pace=write_pace,
    )
    limiter.acquire("write:a", global_exempt=false)
    limiter.acquire("read", global_exempt=false)
    limiter.acquire("read", global_exempt=false)
    assert_eq(clock.slept(), [])
    // Another bucket of the group waits out the interval.
    limiter.acquire("write:b", global_exempt=false)
    assert_eq(clock.slept(), [1000])
    assert_eq(clock.now_unix_ms(), 2000L)
    clock.advance(400)
    limiter.acquire("other", global_exempt=false)
    limiter.acquire("write:a", global_exempt=false)
    assert_eq(clock.slept(), [1000, 600])
    // Spacing counts from the admission, so a later caller finds it served.
    clock.advance(5000)
    limiter.acquire("write:b", global_exempt=false)
    assert_eq(clock.slept(), [1000, 600])
  })
}

///|
test "concurrent acquires in one paced group are admitted one interval apart" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new(start_unix_ms=0L)
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      (_, _) => None,
      gate=() => @fake.SimGate::new(d),
      pace=write_pace,
    )
    let admitted = []
    with_group(d, group => {
      for name in ["write:a", "write:b", "write:a", "read", "write:c"] {
        group.spawn_bg(() => {
          limiter.acquire(name, global_exempt=false)
          admitted.push((name, clock.now_unix_ms()))
          d.pause()
          limiter.release(name, status=200, headers=@model.Headers::empty())
        })
      }
    })
    let writes = admitted.filter(entry => entry.0.has_prefix("write:"))
    assert_eq(writes.map(entry => entry.1), [0L, 1000L, 2000L, 3000L])
    // The unpaced bucket never slept: it was admitted before any pace wait.
    assert_eq(
      admitted.filter(entry => entry.0 == "read").map(entry => entry.1),
      [0L],
    )
  })
}

///|
test "a key learned between acquire and release does not keep the gate" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new(start_unix_ms=1000L)
    let made = Ref(0)
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      @ratelimit.rate_limit_headers(
        remaining="remaining",
        reset_after_seconds="reset-after",
      ),
      gate=() => {
        made.val += 1
        @fake.SimGate::new(d)
      },
      server_key=(_, headers) => headers.get("bucket"),
    )
    limiter.acquire("a", global_exempt=false)
    limiter.release(
      "a",
      status=200,
      headers=limit_headers([
        ("bucket", "hash"),
        ("remaining", "5"),
        ("reset-after", "60"),
      ]),
    )
    // Had the release left a gate keyed by "hash", this would block forever.
    limiter.acquire("a", global_exempt=false)
    limiter.release("a", status=0, headers=@model.Headers::empty())
    assert_eq(made.val, 2)
    assert_eq(
      limiter.state("a"),
      Some({ remaining: 4, reset_at_unix_ms: 61000L, }),
    )
  })
}

///|
test "two buckets keyed to one server window share remaining and reset" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new(start_unix_ms=1000L)
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      @ratelimit.rate_limit_headers(
        remaining="remaining",
        reset_after_seconds="reset-after",
      ),
      server_key=(_, headers) => headers.get("resource"),
    )
    limiter.release(
      "core:read",
      status=200,
      headers=limit_headers([
        ("resource", "core"),
        ("remaining", "2"),
        ("reset-after", "5"),
      ]),
    )
    limiter.release(
      "core:write",
      status=200,
      headers=limit_headers([
        ("resource", "core"),
        ("remaining", "1"),
        ("reset-after", "5"),
      ]),
    )
    assert_eq(
      limiter.state("core:read"),
      Some({ remaining: 1, reset_at_unix_ms: 6000L, }),
    )
    assert_eq(limiter.state("core:write"), limiter.state("core:read"))
    limiter.acquire("core:read", global_exempt=false)
    assert_eq(clock.slept(), [])
    assert_eq(
      limiter.state("core:write"),
      Some({ remaining: 0, reset_at_unix_ms: 6000L, }),
    )
    limiter.acquire("core:write", global_exempt=false)
    assert_eq(clock.slept(), [5000])
    // A bucket no response has keyed keeps its own window.
    assert_eq(limiter.state("search"), None)
  })
}

///|
test "a 429's scope decides whether it blocks its bucket, every bucket or nothing" {
  let d = @driver.Driver::new()
  d.run(() => {
    let clock = @fake.FakeClock::new(start_unix_ms=1000L)
    let limiter = @ratelimit.WindowLimiter::new(
      clock,
      @ratelimit.rate_limit_headers(
        remaining="remaining",
        reset_after_seconds="reset-after",
      ),
      scope=(_, headers) => {
        match headers.get("scope") {
          Some("shared") => Shared
          Some("global") => Global
          Some("ignore") => Ignore
          _ => Bucket
        }
      },
    )
    let too_many = (scope : String) => {
      limit_headers([
        ("scope", scope),
        ("remaining", "3"),
        ("reset-after", "10"),
        ("retry-after", "2"),
      ])
    }
    // Shared: only the parsed state counts; the bucket is not emptied.
    limiter.release("shared", status=429, headers=too_many("shared"))
    assert_eq(
      limiter.state("shared"),
      Some({ remaining: 3, reset_at_unix_ms: 11000L, }),
    )
    limiter.acquire("shared", global_exempt=false)
    assert_eq(clock.slept(), [])
    // Ignore: nothing changes, not even the bucket's earlier state.
    limiter.release("shared", status=429, headers=too_many("ignore"))
    assert_eq(
      limiter.state("shared"),
      Some({ remaining: 2, reset_at_unix_ms: 11000L, }),
    )
    limiter.release("fresh", status=429, headers=too_many("ignore"))
    assert_eq(limiter.state("fresh"), None)
    limiter.acquire("fresh", global_exempt=false)
    assert_eq(clock.slept(), [])
    // Bucket: the bucket waits out the Retry-After, others do not.
    limiter.release("bucket", status=429, headers=too_many("bucket"))
    limiter.acquire("other", global_exempt=false)
    assert_eq(clock.slept(), [])
    limiter.acquire("bucket", global_exempt=false)
    assert_eq(clock.slept(), [2000])
    // Global: every non-exempt request waits, whatever its bucket.
    limiter.release("global", status=429, headers=too_many("global"))
    assert_eq(
      limiter.state("global"),
      Some({ remaining: 3, reset_at_unix_ms: 13000L, }),
    )
    limiter.acquire("other", global_exempt=true)
    assert_eq(clock.slept(), [2000])
    limiter.acquire("other", global_exempt=false)
    assert_eq(clock.slept(), [2000, 2000])
  })
}

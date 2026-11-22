///|
test "PhaseLimits gives the head, the body and Unknown the read limit" {
  let limits : @attempt.PhaseLimits = {
    pool: Some(2),
    connect: Some(3),
    write: Some(4),
    read: Some(5),
  }
  let phases : Array[@mttp_core.Phase] = [
    Pool,
    Dial,
    Write,
    Head,
    Body,
    Unknown,
  ]
  assert_eq(phases.map(phase => limits.of(phase)), [
    Some(2),
    Some(3),
    Some(4),
    Some(5),
    Some(5),
    Some(5),
  ])
}

///|
/// The error `f` raises under `timer`, or None when it returns.
fn timed_out(
  d : @driver.Driver,
  f : async () -> Unit raise @mttp_core.TransportError,
) -> @mttp_core.TransportError? {
  try {
    d.run(() => f())
    None
  } catch {
    @mttp_core.TransportError(..) as e => Some(e)
    _ => None
  }
}

///|
fn describe(e : @mttp_core.TransportError?) -> String {
  match e {
    Some(e) => "\{e}"
    None => "no error"
  }
}

///|
test "a phase starting past the deadline times out without starting" {
  let d = @driver.Driver::new(auto_advance=true)
  let timer = @attempt.AttemptTimer::new(
    @sim.SimClock::new(d),
    @sim.SimTimer::new(d),
    Some(100),
  )
  let started = Ref(0)
  let first = timed_out(d, () => {
    timer.run(Head, () => started.val += 1)
    // The deadline passes between phases.
    @sim.SimClock::new(d).sleep(150)
    timer.run(Body, () => started.val += 1)
  })
  guard first
    is Some(@mttp_core.TransportError(kind=Timeout(ms=100), phase=Body, ..)) else {
    fail("unexpected \{describe(first)}")
  }
  // The body phase never ran: an end already known would have been
  // reported past the deadline otherwise.
  assert_eq(started.val, 1)
  assert_eq(timer.remaining(), Some(0L))
}

///|
test "a phase that waits past the deadline is cancelled and times out" {
  let d = @driver.Driver::new(auto_advance=true)
  let clock = @sim.SimClock::new(d)
  let timer = @attempt.AttemptTimer::new(
    clock,
    @sim.SimTimer::new(d),
    Some(50),
    limits={ ..@attempt.PhaseLimits::none(), read: Some(500), },
  )
  let e = timed_out(d, () => timer.run(Head, () => clock.sleep(1000)))
  guard e
    is Some(@mttp_core.TransportError(kind=Timeout(ms=50), phase=Head, ..)) else {
    fail("unexpected \{describe(e)}")
  }
  assert_eq(d.now(), 50L)
}

///|
test "a phase's own limit is reported when it ends first" {
  let d = @driver.Driver::new(auto_advance=true)
  let clock = @sim.SimClock::new(d)
  let timer = @attempt.AttemptTimer::new(
    clock,
    @sim.SimTimer::new(d),
    Some(5000),
    limits={ ..@attempt.PhaseLimits::none(), write: Some(20), },
  )
  let e = timed_out(d, () => timer.run(Write, () => clock.sleep(1000)))
  guard e
    is Some(@mttp_core.TransportError(kind=Timeout(ms=20), phase=Write, ..)) else {
    fail("unexpected \{describe(e)}")
  }
}

///|
test "failures take the phase, through classify" {
  let d = @driver.Driver::new(auto_advance=true)
  let timer = @attempt.AttemptTimer::new(
    @sim.SimClock::new(d),
    @sim.SimTimer::new(d),
    None,
  )
  let e = timed_out(d, () => {
    timer.run(Head, () => {
      raise @mttp_core.TransportError(
        kind=Network,
        phase=Unknown,
        detail="reset",
      )
    })
  })
  guard e is Some(@mttp_core.TransportError(kind=Network, phase=Head, ..)) else {
    fail("unexpected \{describe(e)}")
  }
  let custom = @attempt.AttemptTimer::new(
    @sim.SimClock::new(d),
    @sim.SimTimer::new(d),
    None,
    classify=(phase, _) => {
      @mttp_core.TransportError(kind=Protocol, phase~, detail="codec")
    },
  )
  let e = timed_out(d, () => custom.run(Dial, () => fail("boom")))
  guard e is Some(@mttp_core.TransportError(kind=Protocol, phase=Dial, ..)) else {
    fail("unexpected \{describe(e)}")
  }
}

///|
test "for_body keeps the deadline for Exchange and swaps it for idle for Stream" {
  let d = @driver.Driver::new(auto_advance=true)
  let clock = @sim.SimClock::new(d)
  let timer = @attempt.AttemptTimer::new(
    clock,
    @sim.SimTimer::new(d),
    Some(100),
    limits={ ..@attempt.PhaseLimits::none(), read: Some(300), },
  )
  // Exchange: the attempt deadline goes on into the body.
  let exchange = timer.for_body(Exchange(max_bytes=10))
  let e = timed_out(d, () => exchange.run(Body, () => clock.sleep(1000)))
  guard e is Some(@mttp_core.TransportError(kind=Timeout(ms=100), ..)) else {
    fail("unexpected \{describe(e)}")
  }
  // Stream: no deadline left, each read bounded by idle and the read limit.
  let stream = timer.for_body(Stream(idle_ms=Some(40)))
  assert_eq(stream.remaining(), None)
  let e = timed_out(d, () => stream.run(Body, () => clock.sleep(1000)))
  guard e is Some(@mttp_core.TransportError(kind=Timeout(ms=40), ..)) else {
    fail("unexpected \{describe(e)}")
  }
  let unbounded = timer.for_body(Stream(idle_ms=None))
  let e = timed_out(d, () => unbounded.run(Body, () => clock.sleep(1000)))
  guard e is Some(@mttp_core.TransportError(kind=Timeout(ms=300), ..)) else {
    fail("unexpected \{describe(e)}")
  }
}

///|
test "body_limit takes the smaller bound for Exchange and the ceiling for Stream" {
  assert_eq(@attempt.body_limit(Exchange(max_bytes=10), ceiling=100), Some(10))
  assert_eq(@attempt.body_limit(Exchange(max_bytes=100), ceiling=10), Some(10))
  assert_eq(@attempt.body_limit(Exchange(max_bytes=10)), Some(10))
  assert_eq(@attempt.body_limit(Stream(idle_ms=None), ceiling=7), Some(7))
  assert_eq(@attempt.body_limit(Stream(idle_ms=None)), None)
}

///|
test "BodyBudget refuses the piece that would cross the bound, near Int max too" {
  let small = @attempt.BodyBudget::new(Some(10))
  small.admit(6)
  small.admit(4)
  let e = try {
    small.admit(1)
    None
  } catch {
    e => Some(e)
  }
  guard e
    is Some(@mttp_core.TransportError(kind=TooLarge(limit=10), phase=Body, ..)) else {
    fail("past the bound was admitted")
  }
  assert_eq(small.count(), 10L)
  // A bound at Int max: the total passes Int max without wrapping.
  let max = 2147483647
  let large = @attempt.BodyBudget::new(Some(max))
  large.admit(max - 1)
  large.admit(1)
  let e = try {
    large.admit(1)
    None
  } catch {
    e => Some(e)
  }
  guard e is Some(@mttp_core.TransportError(kind=TooLarge(..), ..)) else {
    fail("a piece past Int max was admitted")
  }
  // No bound: anything goes.
  let free = @attempt.BodyBudget::new(None)
  free.admit(max)
  free.admit(max)
  assert_eq(free.count(), 4294967294L)
}

///|
test "BodyBudget refuses a declared length past the bound before reading" {
  let budget = @attempt.BodyBudget::new(Some(100))
  budget.check_declared(Some(100L))
  budget.check_declared(None)
  let e = try {
    budget.check_declared(Some(101L))
    None
  } catch {
    e => Some(e)
  }
  guard e
    is Some(@mttp_core.TransportError(kind=TooLarge(limit=100), phase=Body, ..)) else {
    fail("a declared length past the bound was accepted")
  }
}

///|
test "failure keeps a TransportError's phase and classifies anything else" {
  let known = @mttp_core.TransportError(kind=Protocol, phase=Write, detail="x")
  guard @attempt.failure(Head, known)
    is @mttp_core.TransportError(kind=Protocol, phase=Write, ..) else {
    fail("a known phase was replaced")
  }
  guard @attempt.failure(Dial, Failure("refused"))
    is @mttp_core.TransportError(kind=Connect, phase=Dial, ..) else {
    fail("a failure while dialling is not Connect")
  }
  guard @attempt.failure(Body, Failure("reset"))
    is @mttp_core.TransportError(kind=Network, phase=Body, ..) else {
    fail("a failure while reading is not Network")
  }
}

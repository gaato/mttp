// CircuitBreaker over a scripted backend: which outcomes count, how an open
// circuit refuses, and how half-open probes close or reopen it.

///|
/// A backend answering each request with the next scripted status (or
/// failure), recording the URLs it was sent.
priv struct Scripted {
  answers : Array[Result[Int32, @mttp_core.Kind]]
  sent : Array[String]
}

///|
fn Scripted::backend(self : Scripted) -> &@mttp_core.Backend {
  @client.from_fn((request, _) => {
    self.sent.push(request.url)
    guard !self.answers.is_empty() else { return @mttp_core.Response::new(200) }
    match self.answers.remove(0) {
      Ok(status) => @mttp_core.Response::new(status)
      Err(kind) =>
        raise @mttp_core.TransportError(kind~, phase=Dial, detail="scripted")
    }
  })
}

///|
/// Sends one GET and returns its status, or the failure's kind and phase.
fn breaker_send(
  breaker : @client.CircuitBreaker,
  url : String,
) -> Result[Int32, (@mttp_core.Kind, @mttp_core.Phase, Bool)] raise {
  @driver.run_sync(() => {
    let response = breaker.send(
      @mttp_core.Request::get(url),
      @mttp_core.SendOptions::default(),
    ) catch {
      @mttp_core.TransportError(kind~, phase~, ..) as error =>
        return Err((kind, phase, error.is_unsent()))
    }
    response.close()
    Ok(response.status)
  })
}

///|
test "a circuit opens on its failure ratio and refuses unsent until a probe succeeds" {
  let clock = @sim.FakeClock::new()
  let script = Scripted::{
    answers: [Ok(503), Ok(404), Err(Connect), Ok(200), Ok(502), Ok(200)],
    sent: [],
  }
  let breaker = @client.CircuitBreaker::new(
    script.backend(),
    clock~,
    failure_ratio=0.5,
    min_requests=4,
    window_ms=1000,
    open_ms=500,
  )
  let a = "https://a.example/x"
  // 503, a 404 (a success: the origin answered) and a connect failure:
  // 2 of 3 failed, under min_requests.
  assert_eq(breaker_send(breaker, a), Ok(503))
  assert_eq(breaker_send(breaker, a), Ok(404))
  assert_eq(breaker_send(breaker, a), Err((Connect, Dial, true)))
  // The fourth request reaches min_requests: 2 of 4 is the ratio, so the
  // circuit opens although this one succeeded.
  assert_eq(breaker_send(breaker, a), Ok(200))
  assert_eq(script.sent.length(), 4)
  assert_eq(breaker_send(breaker, a), Err((CircuitOpen, Pool, true)))
  // Another origin (here the same host on another port) has its own circuit.
  assert_eq(breaker_send(breaker, "https://a.example:8443/"), Ok(502))
  clock.advance(499)
  assert_eq(
    breaker_send(breaker, "HTTPS://A.EXAMPLE:443/y"),
    Err((CircuitOpen, Pool, true)),
  )
  assert_eq(script.sent.length(), 5)
  // After open_ms, one probe passes; its success closes the circuit.
  clock.advance(1)
  assert_eq(breaker_send(breaker, a), Ok(200))
  assert_eq(breaker_send(breaker, a), Ok(200))
  assert_eq(script.sent.length(), 7)
}

///|
test "a failed probe reopens and half-open admits only its probes" {
  let d = @driver.Driver::new()
  let clock = @sim.SimClock::new(d)
  let statuses = [503, 503]
  let calls = Ref(0)
  let breaker = @client.CircuitBreaker::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      // Each exchange takes 10 ms, so later sends overlap a probe.
      d.sleep(10)
      @mttp_core.Response::new(
        if statuses.is_empty() {
          200
        } else {
          statuses.remove(0)
        },
      )
    }),
    clock~,
    failure_ratio=1.0,
    min_requests=1,
    open_ms=100,
  )
  let send = async fn() -> String {
    let response = breaker.send(
      @mttp_core.Request::get("http://a.example/"),
      @mttp_core.SendOptions::default(),
    ) catch {
      @mttp_core.TransportError(kind~, ..) => return @debug.to_string(kind)
    }
    response.close()
    response.status.to_string()
  }
  let results = d.run(() => {
    let results = [send()]
    d.sleep(100)
    // The probe fails: open again for another 100 ms.
    results.push(send())
    results.push(send())
    d.sleep(100)
    // A second probe while the first is in flight is refused.
    let first = Ref("")
    let task = d.spawn(() => first.val = send())
    d.sleep(1)
    results.push(send())
    ignore(task.wait())
    results.push(first.val)
    results.push(send())
    results
  })
  assert_eq(results, ["503", "503", "CircuitOpen", "CircuitOpen", "200", "200"])
  assert_eq(calls.val, 4)
}

///|
test "local refusals and cancelled probes do not count against the origin" {
  let d = @driver.Driver::new()
  let clock = @sim.SimClock::new(d)
  let script = Scripted::{
    answers: [Err(Invalid), Err(Closed), Err(CircuitOpen), Err(Timeout(ms=5))],
    sent: [],
  }
  let breaker = @client.CircuitBreaker::new(
    script.backend(),
    clock~,
    failure_ratio=0.5,
    min_requests=1,
    open_ms=50,
  )
  let a = "http://a.example/"
  assert_eq(breaker_send(breaker, a), Err((Invalid, Dial, true)))
  assert_eq(breaker_send(breaker, a), Err((Closed, Dial, true)))
  assert_eq(breaker_send(breaker, a), Err((CircuitOpen, Dial, true)))
  // A timeout is the origin's failure.
  assert_eq(breaker_send(breaker, a), Err((Timeout(ms=5), Dial, true)))
  assert_eq(breaker_send(breaker, a), Err((CircuitOpen, Pool, true)))
  // A probe cancelled in flight frees its slot for the next request.
  let gate = @sim.SimCoordination::new(d).signal()
  let calls = Ref(0)
  let slow = @client.CircuitBreaker::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      if calls.val == 1 {
        raise reset_error()
      }
      gate.wait()
      @mttp_core.Response::new(200)
    }),
    clock~,
    min_requests=1,
    open_ms=0,
  )
  let send = async fn() -> String {
    let response = slow.send(
      @mttp_core.Request::get(a),
      @mttp_core.SendOptions::default(),
    ) catch {
      @mttp_core.TransportError(kind~, ..) => return @debug.to_string(kind)
    }
    response.close()
    response.status.to_string()
  }
  let results = d.run(() => {
    let results = [send()]
    let task = d.spawn(() => results.push(send()))
    d.pause()
    results.push(send())
    task.cancel()
    assert_false(task.wait())
    gate.notify()
    results.push(send())
    results
  })
  assert_eq(results, ["Network", "CircuitOpen", "200"])
  assert_eq(calls.val, 3)
}

///|
test "requests without an origin pass uncounted and close refuses later sends" {
  let script = Scripted::{ answers: [Ok(503), Ok(503)], sent: [], }
  let breaker = @client.CircuitBreaker::new(
    script.backend(),
    clock=@sim.FakeClock::new(),
    min_requests=1,
  )
  assert_eq(breaker_send(breaker, "/relative"), Ok(503))
  assert_eq(breaker_send(breaker, "/relative"), Ok(503))
  breaker.close()
  breaker.close()
  assert_eq(breaker_send(breaker, "/relative"), Err((Closed, Pool, true)))
  assert_eq(script.sent.length(), 2)
}

///|
test "the retry rules never retry an open circuit" {
  let open = @mttp_core.TransportError(
    kind=CircuitOpen,
    phase=Pool,
    detail="open",
  )
  assert_true(open.is_unsent())
  let get = @mttp_core.Request::get("https://a.example/")
  for
    rule in [
      @client.RetryPolicy::conservative().rule,
      {
        ..@retry.RetryRule::never(),
        max_retries: 5,
        sent_failures: Any,
        unsent_failures: true,
      },
    ] {
    assert_eq(
      rule.decide(
        Failure(open),
        get.head(),
        attempt=0,
        random=0.0,
        idempotent=true,
        replayable=true,
      ),
      Stop(NotRetryable),
    )
  }
  // Through a Client with retries on: one refusal, no wait, no resend.
  let clock = @sim.FakeClock::new()
  let script = Scripted::{ answers: [Ok(503)], sent: [], }
  let client = @client.Client::new(
    @client.CircuitBreaker::new(script.backend(), clock~, min_requests=1),
    clock,
    retry=@client.RetryPolicy::conservative().with_max_retries(3),
  )
  // The 503 opens the circuit; its retry meets the open circuit and stops.
  let kind = try {
    ignore(
      @driver.run_sync(() => client.send(@client.get("https://a.example/"))),
    )
    None
  } catch {
    @mttp_core.TransportError(kind~, ..) => Some(kind)
    error => raise error
  }
  assert_eq(kind, Some(CircuitOpen))
  assert_eq(script.sent.length(), 1)
  assert_eq(clock.slept().length(), 1)
}

///|
test "the circuit breaker keeps the backend contract" {
  @driver.run_sync(() => {
    let clock = @sim.FakeClock::new()
    @sim.check_backend_contract(
      () => {
        @client.CircuitBreaker::new(
          @client.from_fn((_, _) => @mttp_core.Response::new(200)),
          clock~,
        )
      },
      wrap=inner => @client.CircuitBreaker::new(inner, clock~),
    )
  })
}

///|
/// A backend that always answers 503, counting its calls.
fn unavailable(calls : Ref[Int32]) -> &@mttp.Backend {
  @client.from_fn((_, _) => {
    calls.val += 1
    @mttp.Response::new(503)
  })
}

///|
test "a spent budget stops retries with RetryBudgetSpent" {
  let calls = Ref(0)
  let decisions = []
  let client = @client.Client::new(
    unavailable(calls),
    @sim.FakeClock::new(),
    retry=@client.RetryPolicy::conservative(),
    // Half a retry per request and no per-second floor: the first request
    // may retry once, the second not at all.
    retry_budget=@client.RetryBudget::new(percent=0.5, min_per_second=0),
    observer=attempt => decisions.push(attempt.decision),
  )
  @driver.run_sync(() => {
    ignore(client.send(@client.get("/")))
    ignore(client.send(@client.get("/")))
  })
  assert_eq(calls.val, 3)
  assert_true(decisions[0] is Some(Wait(_)))
  assert_eq(decisions[1], Some(Stop(RetryBudgetSpent)))
  assert_eq(decisions[2], Some(Stop(RetryBudgetSpent)))
}

///|
test "the per-second floor allows retries before any deposit counts" {
  let calls = Ref(0)
  let client = @client.Client::new(
    unavailable(calls),
    @sim.FakeClock::new(),
    retry=@client.RetryPolicy::conservative(),
    retry_budget=@client.RetryBudget::new(
      percent=0.0,
      min_per_second=1,
      window_ms=1000,
    ),
  )
  @driver.run_sync(() => ignore(client.send(@client.get("/"))))
  // One retry per second over a one-second window.
  assert_eq(calls.val, 2)
}

///|
test "withdrawals leave the window as time passes" {
  let calls = Ref(0)
  let clock = @sim.FakeClock::new()
  let client = @client.Client::new(
    unavailable(calls),
    clock,
    retry=@client.RetryPolicy::conservative().with_max_retries(1),
    retry_budget=@client.RetryBudget::new(
      percent=0.0,
      min_per_second=1,
      window_ms=1000,
    ),
  )
  @driver.run_sync(() => {
    ignore(client.send(@client.get("/")))
    ignore(client.send(@client.get("/")))
  })
  assert_eq(calls.val, 3)
  clock.advance(2000)
  @driver.run_sync(() => ignore(client.send(@client.get("/"))))
  assert_eq(calls.val, 5)
}

///|
test "an unlimited budget leaves the decision to the policy" {
  let calls = Ref(0)
  let client = @client.Client::new(
    unavailable(calls),
    @sim.FakeClock::new(),
    retry=@client.RetryPolicy::conservative(),
    retry_budget=@client.RetryBudget::unlimited(),
  )
  @driver.run_sync(() => {
    for _ in 0..<5 {
      ignore(client.send(@client.get("/")))
    }
  })
  // Two retries for each of the five requests.
  assert_eq(calls.val, 15)
}

///|
test "a budget shared by two clients counts both" {
  let calls = Ref(0)
  let budget = @client.RetryBudget::new(percent=0.5, min_per_second=0)
  let make = () => {
    @client.Client::new(
      unavailable(calls),
      @sim.FakeClock::new(),
      retry=@client.RetryPolicy::conservative(),
      retry_budget=budget,
    )
  }
  let first = make()
  let second = make()
  @driver.run_sync(() => {
    ignore(first.send(@client.get("/")))
    ignore(second.send(@client.get("/")))
  })
  // Two deposits allow one retry in all.
  assert_eq(calls.val, 3)
}

///|
test "the budget is charged when a retry is sent, not when it is decided" {
  let calls = Ref(0)
  let clock = @sim.FakeClock::new()
  let client = @client.Client::new(
    unavailable(calls),
    clock,
    retry=@client.RetryPolicy::conservative(),
    // One retry per one-second window.
    retry_budget=@client.RetryBudget::new(
      percent=0.0,
      min_per_second=1,
      window_ms=1000,
    ),
  )
  @driver.run_sync(() => {
    // Decided at 0 ms, sent after a 2000 ms wait: it uses the budget of
    // the window around 2000 ms.
    ignore(
      client.send(@client.get("/"), decide_retry=(result, context) => {
        ignore(result)
        if context.attempt == 0 {
          Wait(2000)
        } else {
          Stop(NotRetryable)
        }
      }),
    )
  })
  assert_eq(calls.val, 2)
  // The window around 2000 ms holds that retry, so an immediate retry
  // is refused. Charged at 0 ms, the retry would have left the window.
  @driver.run_sync(() => {
    ignore(client.send(@client.get("/"), decide_retry=(_, _) => Wait(0)))
  })
  assert_eq(calls.val, 3)
}

///|
test "a retry whose budget ran out during its wait returns the last outcome" {
  let calls = Ref(0)
  let replies = []
  let driver = @driver.Driver::new(auto_advance=true)
  driver.run(() => {
    let clock = @sim.SimClock::new(driver)
    let client = @client.Client::new(
      unavailable(calls),
      clock,
      retry=@client.RetryPolicy::conservative(),
      // One retry per one-second window.
      retry_budget=@client.RetryBudget::new(
        percent=0.0,
        min_per_second=1,
        window_ms=1000,
      ),
    )
    let once = (wait : Int32) => {
      (
        _ : @client.AttemptResult[Result[String, @client.ResponseFailure]],
        context : @client.RetryContext,
      ) => {
        if context.attempt == 0 {
          @retry.Decision::Wait(wait)
        } else {
          Stop(NotRetryable)
        }
      }
    }
    // Both retries are decided at 0 ms while the budget has one left. The
    // 50 ms one is sent first and takes it; the 100 ms one finds it spent.
    ignore(
      driver.spawn(() => {
        replies.push(
          client.send(@client.get("/"), decide_retry=once(100)).status,
        )
      }),
    )
    replies.push(client.send(@client.get("/"), decide_retry=once(50)).status)
    clock.sleep(200)
  })
  assert_eq(calls.val, 3)
  assert_eq(replies, [503, 503])
}

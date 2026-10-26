///|
fn status_error(
  status : Int32,
  headers~ : @model.Headers = @model.Headers::empty(),
) -> Error {
  @client.UnexpectedStatus(
    @model.Response::new(status, headers~).head(),
    body=b"",
  )
}

///|
fn rate_limited(
  retry_after_ms : Int32?,
  headers~ : @model.Headers = @model.Headers::empty(),
) -> Error {
  status_error(
    429,
    headers=match retry_after_ms {
      Some(ms) => headers.set("retry-after-ms", ms.to_string())
      None => headers
    },
  )
}

///|
fn transport_error(error : @model.TransportError) -> Error {
  error
}

///|
test "RetryPolicy presets are the documented rules" {
  let conservative : @client.RetryPolicy = {
    rule: {
      max_retries: 2,
      statuses: [
        { statuses: [Code(429)], methods: Any, },
        {
          statuses: [
            Code(408),
            Code(409),
            Code(500),
            Code(502),
            Code(503),
            Code(504),
          ],
          methods: Idempotent,
        },
      ],
      sent_failures: Idempotent,
      unsent_failures: true,
      override_header: None,
      retry_after: {
        source: MsThenHeader,
        cap: StopAbove(60000),
        zero_means_backoff: false,
      },
      backoff: {
        base_ms: 500,
        max_ms: 30000,
        jitter: Proportional(lo=800, hi=1200),
      },
    },
  }
  assert_eq(@client.RetryPolicy::conservative(), conservative)
  assert_eq(@client.RetryPolicy::default(), conservative)
  assert_eq(@client.RetryPolicy::none(), {
    rule: { ..conservative.rule, max_retries: 0, },
  })
  assert_eq(
    @client.RetryPolicy::from_rule(conservative.rule).with_max_retries(5).rule.max_retries,
    5,
  )
  let caps : Array[@client.RetryAfterCap] = [StopAbove(120000), NoCap]
  for cap in caps {
    let stainless : @client.RetryPolicy = {
      rule: {
        max_retries: 2,
        statuses: [
          {
            statuses: [Code(408), Code(409), Code(429), Range(500, 599)],
            methods: Any,
          },
        ],
        sent_failures: Any,
        unsent_failures: true,
        override_header: Some("x-should-retry"),
        retry_after: { source: MsThenHeader, cap, zero_means_backoff: true, },
        backoff: {
          base_ms: 500,
          max_ms: 8000,
          jitter: Proportional(lo=750, hi=1000),
        },
      },
    }
    assert_eq(@client.RetryPolicy::stainless(cap~), stainless)
  }
  let widened = conservative.allow_non_idempotent()
  assert_eq(widened.rule.sent_failures, Any)
  assert_eq(widened.rule.statuses.map(rule => rule.methods), [Any, Any])
  assert_eq(
    widened.rule.statuses[1].statuses,
    conservative.rule.statuses[1].statuses,
  )
  let listed = @client.RetryPolicy::from_rule({
    ..conservative.rule,
    statuses: [{ statuses: [Code(503)], methods: Listed([Put]), }],
    sent_failures: Never,
  }).allow_non_idempotent()
  assert_eq(listed.rule.statuses[0].methods, Listed([Put]))
  assert_eq(listed.rule.sent_failures, Never)
}

///|
/// Every `attempt error` shape against conservative() for GET, POST and a POST with
/// an idempotency key, at the first failure with random 0.0 (backoff 400 ms).
test "conservative decides every attempt error variant by method" {
  let policy = @client.RetryPolicy::conservative()
  let get = @model.Request::get("/")
  let post = @model.Request::post("/")
  let keyed_post = post.header("idempotency-key", "key")
  let wait : @client.Decision = Wait(400)
  let not_retryable : @client.Decision = Stop(NotRetryable)
  let refused : @client.Decision = Stop(MethodNotAllowed)
  let cases : Array[(Error, @client.Decision, @client.Decision)] = [
    // A failure that proves nothing was sent is retried for any method.
    (
      transport_error(
        @model.TransportError(kind=Connect, phase=Dial, detail="offline"),
      ),
      wait,
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Timeout(ms=1), phase=Pool, detail="timeout"),
      ),
      wait,
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Timeout(ms=1), phase=Dial, detail="timeout"),
      ),
      wait,
      wait,
    ),
    // One after sending only for an idempotent request.
    (
      transport_error(
        @model.TransportError(kind=Timeout(ms=1), phase=Write, detail="timeout"),
      ),
      wait,
      refused,
    ),
    (
      transport_error(
        @model.TransportError(kind=Timeout(ms=1), phase=Head, detail="timeout"),
      ),
      wait,
      refused,
    ),
    (
      transport_error(
        @model.TransportError(kind=Timeout(ms=1), phase=Body, detail="timeout"),
      ),
      wait,
      refused,
    ),
    (
      transport_error(
        @model.TransportError(
          kind=Timeout(ms=1),
          phase=Unknown,
          detail="timeout",
        ),
      ),
      wait,
      refused,
    ),
    (
      transport_error(
        @model.TransportError(kind=Network, phase=Write, detail=""),
      ),
      wait,
      refused,
    ),
    (
      transport_error(
        @model.TransportError(kind=Network, phase=Head, detail=""),
      ),
      wait,
      refused,
    ),
    (
      transport_error(
        @model.TransportError(kind=Network, phase=Body, detail=""),
      ),
      wait,
      refused,
    ),
    (
      transport_error(
        @model.TransportError(kind=Network, phase=Unknown, detail=""),
      ),
      wait,
      refused,
    ),
    (
      transport_error(
        @model.TransportError(kind=Protocol, phase=Head, detail="bad"),
      ),
      not_retryable,
      not_retryable,
    ),
    // A proxy's refusal when its status is in a rule, for any method.
    (
      transport_error(
        @model.TransportError(kind=Proxy(status=502), phase=Dial, detail=""),
      ),
      wait,
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Proxy(status=503), phase=Dial, detail=""),
      ),
      wait,
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Proxy(status=504), phase=Dial, detail=""),
      ),
      wait,
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Proxy(status=500), phase=Dial, detail=""),
      ),
      wait,
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Proxy(status=429), phase=Dial, detail=""),
      ),
      wait,
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Proxy(status=407), phase=Dial, detail=""),
      ),
      not_retryable,
      not_retryable,
    ),
    (
      transport_error(
        @model.TransportError(kind=Proxy(status=403), phase=Dial, detail=""),
      ),
      not_retryable,
      not_retryable,
    ),
    (status_error(408), wait, refused),
    (status_error(409), wait, refused),
    (status_error(500), wait, refused),
    (status_error(502), wait, refused),
    (status_error(503), wait, refused),
    (status_error(504), wait, refused),
    (status_error(429), wait, wait),
    (status_error(400), not_retryable, not_retryable),
    (status_error(501), not_retryable, not_retryable),
    (status_error(505), not_retryable, not_retryable),
    (rate_limited(None), wait, wait),
    (
      @client.Deserialization(
        @model.Response::new(200).head(),
        message="bad",
        body=b"",
      ),
      not_retryable,
      not_retryable,
    ),
    (@client.InvalidRequest(message="bad"), not_retryable, not_retryable),
  ]
  for i, case in cases {
    let (error, idempotent, non_idempotent) = case
    let decide = (request, attempt) => {
      policy.decide(
        error,
        @client.RetryContext::capture(request, attempt~, random=0.0),
      )
    }
    assert_eq(decide(get, 0), idempotent, msg="row \{i} GET")
    assert_eq(decide(keyed_post, 0), idempotent, msg="row \{i} keyed POST")
    assert_eq(decide(post, 0), non_idempotent, msg="row \{i} POST")
    let exhausted : @client.Decision = if @client.outcome_of(error) is Some(_) {
      Stop(Exhausted)
    } else {
      not_retryable
    }
    assert_eq(decide(get, 2), exhausted, msg="row \{i} exhausted")
    assert_eq(
      @client.RetryPolicy::none().decide(
        error,
        @client.RetryContext::capture(get),
      ),
      exhausted,
      msg="row \{i} none",
    )
  }
  let widened = policy.allow_non_idempotent()
  assert_eq(
    widened.decide(
      transport_error(
        @model.TransportError(kind=Timeout(ms=1), phase=Head, detail="timeout"),
      ),
      @client.RetryContext::capture(post, random=0.0),
    ),
    wait,
  )
  assert_eq(
    widened.decide(
      status_error(503),
      @client.RetryContext::capture(post, random=0.0),
    ),
    wait,
  )
}

///|
/// The same table against stainless(): no method restrictions, every 5xx,
/// backoff 375 ms at random 0.0.
test "stainless decides every attempt error variant for any method" {
  let policy = @client.RetryPolicy::stainless(cap=StopAbove(120000))
  let wait : @client.Decision = Wait(375)
  let not_retryable : @client.Decision = Stop(NotRetryable)
  let cases : Array[(Error, @client.Decision)] = [
    (
      transport_error(
        @model.TransportError(kind=Connect, phase=Dial, detail="offline"),
      ),
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Timeout(ms=1), phase=Pool, detail="timeout"),
      ),
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Timeout(ms=1), phase=Dial, detail="timeout"),
      ),
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Timeout(ms=1), phase=Write, detail="timeout"),
      ),
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Timeout(ms=1), phase=Head, detail="timeout"),
      ),
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Timeout(ms=1), phase=Body, detail="timeout"),
      ),
      wait,
    ),
    (
      transport_error(
        @model.TransportError(
          kind=Timeout(ms=1),
          phase=Unknown,
          detail="timeout",
        ),
      ),
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Network, phase=Write, detail=""),
      ),
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Network, phase=Unknown, detail=""),
      ),
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Protocol, phase=Head, detail="bad"),
      ),
      not_retryable,
    ),
    (
      transport_error(
        @model.TransportError(kind=Proxy(status=502), phase=Dial, detail=""),
      ),
      wait,
    ),
    (
      transport_error(
        @model.TransportError(kind=Proxy(status=407), phase=Dial, detail=""),
      ),
      not_retryable,
    ),
    (status_error(408), wait),
    (status_error(409), wait),
    (status_error(429), wait),
    (status_error(500), wait),
    (status_error(501), wait),
    (status_error(529), wait),
    (status_error(599), wait),
    (status_error(400), not_retryable),
    (status_error(404), not_retryable),
    (rate_limited(None), wait),
    (
      @client.Deserialization(
        @model.Response::new(200).head(),
        message="bad",
        body=b"",
      ),
      not_retryable,
    ),
    (@client.InvalidRequest(message="bad"), not_retryable),
  ]
  for i, case in cases {
    let (error, expected) = case
    for request in [@model.Request::get("/"), @model.Request::post("/")] {
      assert_eq(
        policy.decide(error, @client.RetryContext::capture(request, random=0.0)),
        expected,
        msg="row \{i} \{request.meth.to_string()}",
      )
    }
  }
  // x-should-retry overrides the status rules both ways.
  let post = @model.Request::post("/")
  let yes = @model.Headers::of([("x-should-retry", "true")])
  let no = @model.Headers::of([("x-should-retry", "false")])
  let context = @client.RetryContext::capture(post, random=0.0)
  assert_eq(policy.decide(status_error(400, headers=yes), context), wait)
  assert_eq(
    policy.decide(status_error(500, headers=no), context),
    Stop(ServerSaidNo),
  )
  assert_eq(
    policy.decide(rate_limited(None, headers=no), context),
    Stop(ServerSaidNo),
  )
  // Backoff: 500 ms doubling to 8 s, shortened by up to 25 %.
  let delays = [0, 1, 2, 3, 4, 10].map(attempt => {
    policy.rule.backoff.delay_ms(attempt, 0.0)
  })
  assert_eq(delays, [375, 750, 1500, 3000, 6000, 6000])
  assert_eq(policy.rule.backoff.delay_ms(4, 0.999), 7992)
}

///|
test "server delays: sources, caps, zero and HTTP dates" {
  let request = @model.Request::get("/")
  let context = @client.RetryContext::capture(request, random=0.0)
  let policy = @client.RetryPolicy::from_rule({
    ..@client.RetryPolicy::conservative().rule,
    retry_after: {
      source: MsThenHeader,
      cap: StopAbove(1500),
      zero_means_backoff: false,
    },
  })
  let cases : Array[(Error, @client.Decision)] = [
    (rate_limited(Some(0)), Wait(0)),
    (rate_limited(Some(1500)), Wait(1500)),
    (rate_limited(Some(1501)), Stop(RetryAfterTooLong(1501))),
    (
      status_error(503, headers=@model.Headers::of([("retry-after", "1.5")])),
      Wait(1500),
    ),
    (
      status_error(
        503,
        headers=@model.Headers::of([("retry-after-ms", "1501")]),
      ),
      Stop(RetryAfterTooLong(1501)),
    ),
    (
      status_error(503, headers=@model.Headers::of([("retry-after", "bad")])),
      Wait(400),
    ),
  ]
  for i, case in cases {
    assert_eq(policy.decide(case.0, context), case.1, msg="row \{i}")
  }
  // An HTTP date needs the context's clock: before 0.7.0 a Status ignored it.
  let dated = status_error(
    503,
    headers=@model.Headers::of([
      ("retry-after", "Thu, 01 Jan 1970 00:00:02 GMT"),
    ]),
  )
  assert_eq(
    @client.RetryPolicy::conservative().decide(
      dated,
      @client.RetryContext::capture(request, now_unix_ms=500L),
    ),
    Wait(1500),
  )
  // Stainless treats 0 as "no delay given"; the cap decides long delays.
  let zero = rate_limited(Some(0))
  assert_eq(
    @client.RetryPolicy::stainless(cap=NoCap).decide(zero, context),
    Wait(375),
  )
  let long = rate_limited(Some(600000))
  assert_eq(
    @client.RetryPolicy::stainless(cap=StopAbove(120000)).decide(long, context),
    Stop(RetryAfterTooLong(600000)),
  )
  assert_eq(
    @client.RetryPolicy::stainless(cap=NoCap).decide(long, context),
    Wait(600000),
  )
  // A rule that ignores server delays ignores a parsed retry_after_ms too.
  let ignoring = @client.RetryPolicy::from_rule({
    ..policy.rule,
    retry_after: { ..policy.rule.retry_after, source: Ignore, },
  })
  assert_eq(ignoring.decide(rate_limited(Some(1200)), context), Wait(400))
}

///|
test "the context's remaining time and replayability stop a retry" {
  let get = @model.Request::get("/")
  let policy = @client.RetryPolicy::conservative()
  let error = status_error(503)
  assert_eq(
    policy.decide(
      error,
      @client.RetryContext::capture(get, random=0.0, remaining_ms=401L),
    ),
    Wait(400),
  )
  assert_eq(
    policy.decide(
      error,
      @client.RetryContext::capture(get, random=0.0, remaining_ms=400L),
    ),
    Stop(Budget(400)),
  )
  assert_eq(
    policy.decide(error, @client.RetryContext::capture(get, replayable=false)),
    Stop(NotReplayable),
  )
  let context = @client.RetryContext::capture(
    get,
    bucket="b",
    attempt=1,
    random=0.25,
    now_unix_ms=7L,
  )
  assert_eq(
    (
      context.bucket,
      context.attempt,
      context.random,
      context.now_unix_ms,
      context.remaining_ms,
      context.replayable,
    ),
    ("b", 1, 0.25, 7L, None, true),
  )
}

///|
// Backoff without jitter: 100, 200, 400, ... ms, so every wait is exact.
fn rule() -> @retry.RetryRule {
  {
    max_retries: 3,
    statuses: [
      { statuses: [Code(429)], methods: Any, },
      { statuses: [Code(408), Range(500, 599)], methods: Idempotent, },
      {
        statuses: [Code(409)],
        methods: Listed([Other("put"), Other("Patch")]),
      },
      { statuses: [Code(418)], methods: Never, },
    ],
    sent_failures: Idempotent,
    unsent_failures: true,
    override_header: Some("x-should-retry"),
    retry_after: {
      source: MsThenHeader,
      cap: NoCap,
      zero_means_backoff: false,
    },
    backoff: { base_ms: 100, max_ms: 1000, jitter: NoJitter, },
  }
}

///|
fn response(
  status : Int32,
  pairs : Array[(String, String)],
) -> @retry.AttemptOutcome {
  Response(status~, headers=@model.Headers::of(pairs))
}

///|
struct Empty {}

///|
impl @model.BodyStream for Empty with fn read_some(_) {
  None
}

///|
impl @model.BodyStream for Empty with fn close(_) {
  ()
}

///|
test "decide covers every step in order" {
  let r = rule()
  let get = @model.Request::get("/")
  let post = @model.Request::post("/")
  let keyed = post.header("Idempotency-Key", "k-1")
  let fresh_stream = post.body_stream(Empty::{ })
  let sent_stream = post.body_stream(Empty::{ })
  if sent_stream.body is Stream(stream) {
    stream.take().close()
  }
  let s503 = response(503, [])
  let date = "Sun, 06 Nov 1994 08:49:37 GMT"
  let date_ms = 784111777000L
  let cases : Array[(String, @retry.Decision, @retry.Decision)] = [
    // 1. Exhausted
    (
      "first failure",
      decide_request(r, s503, get, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "last retry",
      decide_request(r, s503, get, attempt=2, random=0.0),
      Wait(400),
    ),
    (
      "exhausted",
      decide_request(r, s503, get, attempt=3, random=0.0),
      Stop(Exhausted),
    ),
    (
      "exhausted before replayable",
      decide_request(r, s503, get, attempt=3, random=0.0, replayable=false),
      Stop(Exhausted),
    ),
    (
      "exhausted before override",
      decide_request(
        r,
        response(503, [("x-should-retry", "true")]),
        get,
        attempt=4,
        random=0.0,
      ),
      Stop(Exhausted),
    ),
    (
      "never retries",
      decide_request(
        @retry.RetryRule::never(),
        s503,
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(Exhausted),
    ),
    // 2. Replayable
    (
      "replayable param false",
      decide_request(r, s503, get, attempt=0, random=0.0, replayable=false),
      Stop(NotReplayable),
    ),
    (
      "sent stream body",
      decide_request(r, response(429, []), sent_stream, attempt=0, random=0.0),
      Stop(NotReplayable),
    ),
    (
      "untaken stream body",
      decide_request(r, response(429, []), fresh_stream, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "replayable param true overrides",
      decide_request(
        r,
        response(429, []),
        sent_stream,
        attempt=0,
        random=0.0,
        replayable=true,
      ),
      Wait(100),
    ),
    (
      "replayable before override",
      decide_request(
        r,
        response(503, [("x-should-retry", "true")]),
        get,
        attempt=0,
        random=0.0,
        replayable=false,
      ),
      Stop(NotReplayable),
    ),
    // 3. Override header
    (
      "override true retries a 200 POST",
      decide_request(
        r,
        response(200, [("X-Should-Retry", " TRUE ")]),
        post,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "override true retries a forbidden method",
      decide_request(
        r,
        response(418, [("x-should-retry", "true")]),
        get,
        attempt=1,
        random=0.0,
      ),
      Wait(200),
    ),
    (
      "override false stops a retryable status",
      decide_request(
        r,
        response(429, [("x-should-retry", "False")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(ServerSaidNo),
    ),
    (
      "override garbage is ignored: retryable",
      decide_request(
        r,
        response(503, [("x-should-retry", "maybe")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "override garbage is ignored: not retryable",
      decide_request(
        r,
        response(200, [("x-should-retry", "1")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    (
      "no override header configured",
      decide_request(
        { ..r, override_header: None, },
        response(200, [("x-should-retry", "true")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    // 4. Statuses and methods
    (
      "429 any method",
      decide_request(r, response(429, []), post, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "408 code idempotent",
      decide_request(r, response(408, []), get, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "range low bound",
      decide_request(r, response(500, []), get, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "range high bound",
      decide_request(r, response(599, []), get, attempt=0, random=0.0),
      Wait(100),
    ),
    (
      "below range",
      decide_request(r, response(499, []), get, attempt=0, random=0.0),
      Stop(NotRetryable),
    ),
    (
      "above range",
      decide_request(r, response(600, []), get, attempt=0, random=0.0),
      Stop(NotRetryable),
    ),
    (
      "503 POST not idempotent",
      decide_request(r, s503, post, attempt=0, random=0.0),
      Stop(MethodNotAllowed),
    ),
    (
      "503 POST with idempotency key",
      decide_request(r, s503, keyed, attempt=0, random=0.0),
      Stop(MethodNotAllowed),
    ),
    (
      "idempotent param true for POST",
      decide_request(r, s503, post, attempt=0, random=0.0, idempotent=true),
      Wait(100),
    ),
    (
      "idempotent param false for GET",
      decide_request(r, s503, get, attempt=0, random=0.0, idempotent=false),
      Stop(MethodNotAllowed),
    ),
    (
      "listed method",
      decide_request(
        r,
        response(409, []),
        @model.Request::put("/"),
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "listed ignores case",
      decide_request(
        r,
        response(409, []),
        @model.Request::new(Other("pAtCh"), "/"),
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "unlisted method",
      decide_request(r, response(409, []), post, attempt=0, random=0.0),
      Stop(MethodNotAllowed),
    ),
    (
      "never methods",
      decide_request(r, response(418, []), get, attempt=0, random=0.0),
      Stop(MethodNotAllowed),
    ),
    // 4. Failures
    (
      "protocol never",
      decide_request(
        r,
        Failure(TransportError(kind=Protocol, phase=Head, detail="bad")),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    (
      "connect any method",
      decide_request(
        r,
        Failure(TransportError(kind=Connect, phase=Dial, detail="refused")),
        post,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "pool timeout any method",
      decide_request(
        r,
        Failure(
          TransportError(kind=Timeout(ms=10), phase=Pool, detail="timeout"),
        ),
        post,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "dial timeout any method",
      decide_request(
        r,
        Failure(
          TransportError(kind=Timeout(ms=10), phase=Dial, detail="timeout"),
        ),
        post,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "unsent failures off",
      decide_request(
        { ..r, unsent_failures: false, },
        Failure(TransportError(kind=Connect, phase=Dial, detail="refused")),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    (
      "proxy status matches a rule, method ignored",
      decide_request(
        r,
        Failure(
          TransportError(
            kind=Proxy(status=502),
            phase=Dial,
            detail="bad gateway",
          ),
        ),
        post,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "proxy status matches no rule",
      decide_request(
        r,
        Failure(
          TransportError(kind=Proxy(status=407), phase=Dial, detail="auth"),
        ),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    (
      "proxy with unsent failures off",
      decide_request(
        { ..r, unsent_failures: false, },
        Failure(
          TransportError(
            kind=Proxy(status=502),
            phase=Dial,
            detail="bad gateway",
          ),
        ),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    (
      "head timeout idempotent",
      decide_request(
        r,
        Failure(
          TransportError(kind=Timeout(ms=10), phase=Head, detail="timeout"),
        ),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "head timeout POST",
      decide_request(
        r,
        Failure(
          TransportError(kind=Timeout(ms=10), phase=Head, detail="timeout"),
        ),
        post,
        attempt=0,
        random=0.0,
      ),
      Stop(MethodNotAllowed),
    ),
    (
      "network POST declared idempotent",
      decide_request(
        r,
        Failure(TransportError(kind=Network, phase=Write, detail="reset")),
        post,
        attempt=0,
        random=0.0,
        idempotent=true,
      ),
      Wait(100),
    ),
    (
      "network keyed POST",
      decide_request(
        r,
        Failure(TransportError(kind=Network, phase=Body, detail="reset")),
        keyed,
        attempt=0,
        random=0.0,
      ),
      Stop(MethodNotAllowed),
    ),
    (
      "sent failures never",
      decide_request(
        { ..r, sent_failures: Never, },
        Failure(
          TransportError(kind=Timeout(ms=10), phase=Unknown, detail="timeout"),
        ),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(NotRetryable),
    ),
    (
      "sent failures any",
      decide_request(
        { ..r, sent_failures: Any, },
        Failure(TransportError(kind=Network, phase=Head, detail="reset")),
        post,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "sent failures listed",
      decide_request(
        { ..r, sent_failures: Listed([Post]), },
        Failure(TransportError(kind=Network, phase=Head, detail="reset")),
        post,
        attempt=0,
        random=0.0,
      ),
      Wait(100),
    ),
    (
      "sent failures listed, other method",
      decide_request(
        { ..r, sent_failures: Listed([Post]), },
        Failure(TransportError(kind=Network, phase=Head, detail="reset")),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(MethodNotAllowed),
    ),
    // 5. Server delay
    (
      "retry-after-ms first",
      decide_request(
        r,
        response(429, [("retry-after-ms", "1500"), ("retry-after", "9")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(1500),
    ),
    (
      "retry-after seconds",
      decide_request(
        r,
        response(429, [("retry-after", "2")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(2000),
    ),
    (
      "header source reads only retry-after",
      decide_request(
        {
          ..r,
          retry_after: {
            source: Header,
            cap: NoCap,
            zero_means_backoff: false,
          },
        },
        response(429, [("retry-after-ms", "1500")]),
        get,
        attempt=1,
        random=0.0,
      ),
      Wait(200),
    ),
    (
      "header source seconds",
      decide_request(
        {
          ..r,
          retry_after: {
            source: Header,
            cap: NoCap,
            zero_means_backoff: false,
          },
        },
        response(429, [("retry-after", "2.5")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(2500),
    ),
    (
      "header source date with now",
      decide_request(
        {
          ..r,
          retry_after: {
            source: Header,
            cap: NoCap,
            zero_means_backoff: false,
          },
        },
        response(429, [("retry-after", date)]),
        get,
        attempt=0,
        random=0.0,
        now_unix_ms=date_ms - 5000L,
      ),
      Wait(5000),
    ),
    (
      "http date with now",
      decide_request(
        r,
        response(429, [("retry-after", date)]),
        get,
        attempt=0,
        random=0.0,
        now_unix_ms=date_ms - 7000L,
      ),
      Wait(7000),
    ),
    (
      "http date without now uses backoff",
      decide_request(
        r,
        response(429, [("retry-after", date)]),
        get,
        attempt=1,
        random=0.0,
      ),
      Wait(200),
    ),
    (
      "ignored source uses backoff",
      decide_request(
        {
          ..r,
          retry_after: {
            source: Ignore,
            cap: NoCap,
            zero_means_backoff: false,
          },
        },
        response(429, [("retry-after", "2")]),
        get,
        attempt=1,
        random=0.0,
      ),
      Wait(200),
    ),
    (
      "zero means now",
      decide_request(
        r,
        response(429, [("retry-after", "0")]),
        get,
        attempt=1,
        random=0.0,
      ),
      Wait(0),
    ),
    (
      "zero means backoff",
      decide_request(
        {
          ..r,
          retry_after: {
            source: MsThenHeader,
            cap: NoCap,
            zero_means_backoff: true,
          },
        },
        response(429, [("retry-after", "0")]),
        get,
        attempt=1,
        random=0.0,
      ),
      Wait(200),
    ),
    (
      "stop cap at the limit",
      decide_request(
        {
          ..r,
          retry_after: {
            source: MsThenHeader,
            cap: StopAbove(1000),
            zero_means_backoff: false,
          },
        },
        response(429, [("retry-after-ms", "1000")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(1000),
    ),
    (
      "stop cap over the limit",
      decide_request(
        {
          ..r,
          retry_after: {
            source: MsThenHeader,
            cap: StopAbove(1000),
            zero_means_backoff: false,
          },
        },
        response(429, [("retry-after-ms", "1001")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Stop(RetryAfterTooLong(1001)),
    ),
    (
      "fallback cap at the limit",
      decide_request(
        {
          ..r,
          retry_after: {
            source: MsThenHeader,
            cap: BackoffAbove(1000),
            zero_means_backoff: false,
          },
        },
        response(429, [("retry-after-ms", "1000")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(1000),
    ),
    (
      "fallback cap over the limit",
      decide_request(
        {
          ..r,
          retry_after: {
            source: MsThenHeader,
            cap: BackoffAbove(1000),
            zero_means_backoff: false,
          },
        },
        response(429, [("retry-after", "60")]),
        get,
        attempt=2,
        random=0.0,
      ),
      Wait(400),
    ),
    (
      "no cap",
      decide_request(
        r,
        response(429, [("retry-after", "3600")]),
        get,
        attempt=0,
        random=0.0,
      ),
      Wait(3600000),
    ),
    (
      "server delay param wins over headers",
      decide_request(
        r,
        response(429, [("retry-after", "2")]),
        get,
        attempt=0,
        random=0.0,
        server_delay_ms=750,
      ),
      Wait(750),
    ),
    (
      "server delay param applies to failures",
      decide_request(
        r,
        Failure(TransportError(kind=Connect, phase=Dial, detail="refused")),
        get,
        attempt=0,
        random=0.0,
        server_delay_ms=750,
      ),
      Wait(750),
    ),
    (
      "failures have no server delay",
      decide_request(
        r,
        Failure(TransportError(kind=Connect, phase=Dial, detail="refused")),
        get,
        attempt=2,
        random=0.0,
      ),
      Wait(400),
    ),
    (
      "negative server delay counts as zero",
      decide_request(r, s503, get, attempt=0, random=0.0, server_delay_ms=-5),
      Wait(0),
    ),
    (
      "server delay param zero means backoff",
      decide_request(
        {
          ..r,
          retry_after: {
            source: MsThenHeader,
            cap: NoCap,
            zero_means_backoff: true,
          },
        },
        s503,
        get,
        attempt=1,
        random=0.0,
        server_delay_ms=0,
      ),
      Wait(200),
    ),
    (
      "server delay param is capped",
      decide_request(
        {
          ..r,
          retry_after: {
            source: MsThenHeader,
            cap: StopAbove(500),
            zero_means_backoff: false,
          },
        },
        s503,
        get,
        attempt=0,
        random=0.0,
        server_delay_ms=750,
      ),
      Stop(RetryAfterTooLong(750)),
    ),
    // 7. Budget
    (
      "wait equal to budget stops",
      decide_request(r, s503, get, attempt=2, random=0.0, remaining_ms=400L),
      Stop(Budget(400)),
    ),
    (
      "wait under budget",
      decide_request(r, s503, get, attempt=2, random=0.0, remaining_ms=401L),
      Wait(400),
    ),
    (
      "server delay over budget",
      decide_request(
        r,
        response(429, [("retry-after", "2")]),
        get,
        attempt=0,
        random=0.0,
        remaining_ms=1000L,
      ),
      Stop(Budget(2000)),
    ),
    (
      "spent budget stops even a zero wait",
      decide_request(
        r,
        s503,
        get,
        attempt=0,
        random=0.0,
        server_delay_ms=0,
        remaining_ms=0L,
      ),
      Stop(Budget(0)),
    ),
  ]
  for case in cases {
    let (name, actual, expected) = case
    assert_eq(actual, expected, msg=name)
  }
}

///|
test "decide passes random to the backoff" {
  let r = {
    ..rule(),
    backoff: { base_ms: 1000, max_ms: 30000, jitter: Full, },
  }
  let get = @model.Request::get("/")
  assert_eq(
    decide_request(r, response(503, []), get, attempt=1, random=0.25),
    Wait(500),
  )
}

///|
test "outcome debug representation" {
  let outcome = @retry.Failure(
    @model.TransportError(kind=Connect, phase=Dial, detail="refused"),
  )
  debug_inspect(
    outcome,
    content="Failure(TransportError(kind=Connect, phase=Dial, detail=\"refused\"))",
  )
}

///|
fn decide_request(
  rule : @retry.RetryRule,
  outcome : @retry.AttemptOutcome,
  request : @model.Request,
  attempt~ : Int32,
  random~ : Double,
  now_unix_ms? : Int64,
  remaining_ms? : Int64,
  server_delay_ms? : Int32,
  idempotent? : Bool,
  replayable? : Bool,
) -> @retry.Decision {
  rule.decide(
    outcome,
    request.head(),
    attempt~,
    random~,
    now_unix_ms?,
    remaining_ms?,
    server_delay_ms?,
    idempotent=idempotent.unwrap_or_else(() => @model.is_idempotent(request)),
    replayable=replayable.unwrap_or_else(() => request.body.is_replayable()),
  )
}

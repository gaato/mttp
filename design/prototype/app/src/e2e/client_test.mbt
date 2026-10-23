///|
struct GhUser {
  id : Int
  name : String
} derive(FromJson, Debug)

///|
suberror RateLimitedInBody derive(Debug)

///|
struct GitHubRetry {
  policy : @client.RetryPolicy
}

///|
impl @client.RetryDecider for GitHubRetry with decide(self, e, ctx) {
  match e {
    RateLimitedInBody => if ctx.attempt < 2 { Wait(1000) } else { Stop(Exhausted) }
    _ => @client.RetryDecider::decide(self.policy, e, ctx)
  }
}

///|
struct LogLimiter {
  log : Array[String]
}

///|
impl @client.RateLimiter for LogLimiter with acquire(self, bucket, global_exempt~) {
  self.log.push("acquire \{bucket} \{global_exempt}")
}

///|
impl @client.RateLimiter for LogLimiter with release(self, bucket, status~, headers~) {
  self.log.push("release \{bucket} \{status} \{headers.get("x-ratelimit-remaining").unwrap_or("-")}")
}

///|
test "client usage: GraphQL rate limit inside a 200; base_url prefix join; defaults; release sees the head" {
  let n : Ref[Int] = { val: 0 }
  let seen = []
  let backend = @client.from_fn((req, opts) => {
    n.val += 1
    seen.push((req.url, req.headers.get("accept"), req.headers.get("authorization"), opts.body_deadline))
    let body = if n.val == 1 { b"{\"errors\":[\"RATE_LIMITED\"]}" } else { b"{\"id\":1,\"name\":\"gaato\"}" }
    @model.Response::new(200, headers=@model.Headers::of([("x-ratelimit-remaining", "\{5 - n.val}")]), body=Bytes(body))
  })
  let clock = @fake.FakeClock::new()
  let limiter = LogLimiter::{ log: [] }
  let client = @client.Client::new(
    backend,
    clock,
    base_url="https://ghe.example.com/api/v3",
    headers=@model.Headers::of([("accept", "application/vnd.github+json"), ("authorization", "Bearer t")]),
    retry=GitHubRetry::{ policy: @client.RetryPolicy::conservative() },
    limiter~,
  )
  let reader : @client.ResponseAs[GhUser] = @client.as_bytes().map(b => {
    let j = @json.parse(@utf8.decode(b))
    if j is { "errors": _, .. } { raise RateLimitedInBody }
    @json.from_json(j)
  })
  let reply = @testing.run_sync(async fn() {
    client.send(@client.ClientRequest::new(
      @model.Request::post("/graphql").header("accept", "application/json").attribute(@client.rate_limit_bucket, "graphql"),
      reader,
    ))
  })
  debug_inspect(reply.body, content="{ id: 1, name: \"gaato\" }")
  assert_eq(clock.slept(), [1000])
  // the request's own accept wins over the default; authorization is defaulted
  assert_eq(seen[0], ("https://ghe.example.com/api/v3/graphql", Some("application/json"), Some("Bearer t"), true))
  // release used the 200's head although the reader raised (S-12)
  assert_eq(limiter.log, ["acquire graphql false", "release graphql 200 4", "acquire graphql false", "release graphql 200 3"])
}

///|
test "RT-07: the backend learns whether the body is buffered" {
  let modes = []
  let backend = @client.from_fn((_req, opts) => {
    modes.push(opts.body_deadline)
    @model.Response::new(200, body=Bytes(b"x"))
  })
  let c = @client.Client::new(backend, @fake.FakeClock::new())
  ignore(@testing.run_sync(async fn() { c.send(@client.ClientRequest::new(@model.Request::get("/a"), @client.as_bytes())) }))
  ignore(@testing.run_sync(async fn() {
    c.send(@client.ClientRequest::new(@model.Request::get("/a"), @client.as_stream(async fn(_h, s) { ignore(s.read_some()) })))
  }))
  assert_eq(modes, [true, false])
}

///|
struct NeverTimer {}

///|
impl @clock.Timer for NeverTimer with within(_self, _ms, _f) {
  false
}

///|
test "Timer is only a fallback enforcer: an expired attempt is TransportError(Timeout)" {
  let backend = @client.from_fn((_req, _opts) => @model.Response::new(200))
  let c = @client.Client::new(backend, @fake.FakeClock::new(), timer=NeverTimer::{  }, total_ms=250)
  let r = try {
    Ok(@testing.run_sync(async fn() { c.send(@client.ClientRequest::new(@model.Request::get("/a"), @client.ignore_body())) }))
  } catch {
    e => Err(e)
  }
  assert_true(r is Err(@model.TransportError(kind=Timeout(ms=250), ..)))
}

///|
test "replay_safe attribute: a POST 503 is retried only when marked" {
  let n : Ref[Int] = { val: 0 }
  let backend = @client.from_fn((_req, _opts) => {
    n.val += 1
    @model.Response::new(if n.val == 1 { 503 } else { 200 })
  })
  let clock = @fake.FakeClock::new()
  let c = @client.Client::new(backend, clock, retry=@client.RetryPolicy::conservative(), random=() => 0.0)
  let r = try {
    Ok(@testing.run_sync(async fn() { c.send(@client.ClientRequest::new(@model.Request::post("/m").body_text("x"), @client.ignore_body())) }))
  } catch {
    e => Err(e)
  }
  assert_true(r is Err(@client.UnexpectedStatus({ status: 503, .. }, ..)))
  n.val = 0
  ignore(@testing.run_sync(async fn() {
    c.send(@client.ClientRequest::new(@model.Request::post("/m").body_text("x").attribute(@model.replay_safe, true), @client.ignore_body()))
  }))
  assert_eq(clock.slept(), [500])
}

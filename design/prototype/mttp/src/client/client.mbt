///|
/// The typed result of Client::send (sttp Response[T]).
pub(all) struct Reply[T] {
  status : Int
  headers : @model.Headers
  body : T
  request : @model.RequestHead
  attributes : @model.Attributes
}

///|
pub(all) struct RetryContext {
  request : @model.Request
  bucket : String
  attempt : Int
  random : Double
  now_unix_ms : Int64
  remaining_ms : Int64?
  replayable : Bool
}

///|
/// Kept for deciders' tests (github retry_wbtest uses RetryContext::new).
pub fn RetryContext::new(
  request : @model.Request,
  attempt~ : Int,
  bucket? : String = "default",
  random? : Double = 0.0,
  now_unix_ms? : Int64 = 0L,
  remaining_ms? : Int64,
  replayable? : Bool = true,
) -> RetryContext {
  { request, bucket, attempt, random, now_unix_ms, remaining_ms, replayable }
}

///|
pub(open) trait RetryDecider {
  decide(Self, Error, RetryContext) -> @retry.Decision
}

///|
pub(all) struct RetryPolicy {
  rule : @retry.RetryRule
} derive(Eq, Debug)

///|
pub fn RetryPolicy::none() -> RetryPolicy {
  { rule: @retry.RetryRule::never() }
}

///|
pub fn RetryPolicy::conservative() -> RetryPolicy {
  { rule: { max_retries: 2, statuses: [429, 502, 503, 504], unsent_failures: true, base_delay_ms: 500 } }
}

///|
pub fn outcome_of(e : Error) -> @retry.AttemptOutcome? {
  match e {
    UnexpectedStatus(h, ..) => Some(Response(status=h.status, headers=h.headers))
    @model.TransportError(..) as t => Some(Failure(t))
    _ => None
  }
}

///|
pub impl RetryDecider for RetryPolicy with decide(self, e, ctx) {
  match outcome_of(e) {
    Some(o) => self.rule.decide(o, ctx.request, attempt=ctx.attempt, random=ctx.random, replayable=ctx.replayable)
    None => Stop(NotRetryable)
  }
}

///|
pub(open) trait RateLimiter {
  async fn acquire(Self, String, global_exempt~ : Bool) -> Unit
  async fn release(Self, String, status~ : Int, headers~ : @model.Headers) -> Unit
}

///|
/// The single per-request channel for policy data.
pub let rate_limit_bucket : @model.AttributeKey[String] = @model.AttributeKey::new("rate_limit_bucket")

///|
pub let global_exempt : @model.AttributeKey[Bool] = @model.AttributeKey::new("global_exempt")

///|
/// Metadata for observers and logs; the endpoint interpreter sets it and
/// also uses it as the bucket when no bucket is set.
pub let operation_id : @model.AttributeKey[String] = @model.AttributeKey::new("operation_id")

///|
pub(all) struct Attempt {
  request : @model.RequestHead
  bucket : String
  attempt : Int
  status : Int
  headers : @model.Headers
  duration_ms : Int64
  error : Error?
  decision : @retry.Decision?
}

///|
/// Backend + defaults + policy: sdk-runtime's Client generalised to
/// ClientRequest[T]. The only sending path.
pub struct Client {
  priv backend : &Backend
  priv clock : &@clock.Clock
  priv base_url : String
  priv headers : @model.Headers
  priv retry : &RetryDecider?
  priv limiter : &RateLimiter?
  priv timer : &@clock.Timer?
  priv total_ms : Int?
  priv observer : ((Attempt) -> Unit)?
  priv random : () -> Double
}

///|
pub fn Client::new(
  backend : &Backend,
  clock : &@clock.Clock,
  base_url? : String = "",
  headers? : @model.Headers = @model.Headers::empty(),
  retry? : &RetryDecider,
  limiter? : &RateLimiter,
  timer? : &@clock.Timer,
  total_ms? : Int,
  observer? : (Attempt) -> Unit,
  random? : () -> Double = @clock.default_random,
) -> Client {
  { backend, clock, base_url, headers, retry, limiter, timer, total_ms, observer, random }
}

///|
pub fn Client::close(self : Client) -> Unit {
  self.backend.close()
}

///|
/// Defaults first; a header the request sets itself wins.
fn merge_headers(defaults : @model.Headers, own : @model.Headers) -> @model.Headers {
  let mut out = own
  for p in defaults.iter() {
    if own.get(p.0) is None {
      out = out.add(p.0, p.1)
    }
  }
  out
}

///|
priv enum Exchange[T] {
  Done(T)
  Pending(@model.Response)
}

///|
async fn[T] attempt_once(
  backend : &Backend,
  raw : @model.Request,
  opts : RequestOptions,
  ra : ResponseAs[T],
  seen : Ref[@model.ResponseHead?],
  seen_attrs : Ref[@model.Attributes],
) -> Exchange[T] {
  let resp = backend.send(raw, opts)
  let head = resp.head()
  seen.val = Some(head)
  seen_attrs.val = resp.attributes
  if !(ra.accept_head)(head) {
    let body = read_body(resp.body, max_error_body) catch {
      _ => {
        resp.close()
        b""
      }
    }
    resp.close()
    (ra.reject)(head, body)
    raise UnexpectedStatus(head, body~)
  }
  if ra.streaming {
    Pending(resp)
  } else {
    defer resp.close()
    Done((ra.read)(head, resp.body, opts))
  }
}

///|
pub async fn[T] Client::send(self : Client, r : ClientRequest[T]) -> Reply[T] {
  let raw = {
    ..r.raw,
    url: @model.join_url(self.base_url, r.raw.url),
    headers: merge_headers(self.headers, r.raw.headers),
  }
  let bucket = match raw.attributes.get(rate_limit_bucket) {
    Some(b) => b
    None => "default"
  }
  let exempt = raw.attributes.get(global_exempt).unwrap_or(false)
  let replayable = r.body_fn is Some(_) || raw.body.is_replayable()
  let start = self.clock.now_unix_ms()
  let (ex, head, attributes) = for n = 0; ; n = n + 1 {
    let remaining = self.total_ms.map(t => t.to_int64() - (self.clock.now_unix_ms() - start))
    let timeout_ms = match (r.options.timeout_ms, remaining) {
      (Some(a), Some(b)) => Some(if a < b.to_int() { a } else { b.to_int() })
      (None, Some(b)) => Some(b.to_int())
      (a, None) => a
    }
    let opts = { ..r.options, timeout_ms, body_deadline: !r.response_as.streaming }
    let attempt_raw = match r.body_fn {
      Some(f) => { ..raw, body: Bytes(f()) }
      None => raw
    }
    if self.limiter is Some(l) {
      l.acquire(bucket, global_exempt=exempt)
    }
    let t0 = self.clock.now_unix_ms()
    let seen : Ref[@model.ResponseHead?] = { val: None }
    let seen_attrs : Ref[@model.Attributes] = { val: @model.Attributes::empty() }
    let res : Result[Exchange[T], Error] = try {
      match (self.timer, opts.timeout_ms) {
        (Some(t), Some(ms)) => {
          // fallback enforcer for backends that ignore timeout_ms
          let out : Ref[Result[Exchange[T], Error]?] = { val: None }
          let finished = t.within(ms, async fn() noraise {
            let res : Result[Exchange[T], Error] = try {
              Ok(attempt_once(self.backend, attempt_raw, opts, r.response_as, seen, seen_attrs))
            } catch {
              e => Err(e)
            }
            out.val = Some(res)
          })
          match (finished, out.val) {
            (true, Some(Ok(x))) => Ok(x)
            (true, Some(Err(e))) => Err(e)
            _ => Err(@model.TransportError(kind=Timeout(ms~), phase=Unknown, detail="attempt deadline"))
          }
        }
        _ => Ok(attempt_once(self.backend, attempt_raw, opts, r.response_as, seen, seen_attrs))
      }
    } catch {
      e => Err(e)
    }
    // release sees the head as soon as it is known, before the reader ran
    let (status, headers) = match seen.val {
      Some(h) => (h.status, h.headers)
      None => (0, @model.Headers::empty())
    }
    if self.limiter is Some(l) {
      l.release(bucket, status~, headers~)
    }
    let now = self.clock.now_unix_ms()
    match res {
      Ok(x) => {
        if self.observer is Some(o) {
          o({ request: raw.head(), bucket, attempt: n, status, headers, duration_ms: now - t0, error: None, decision: None })
        }
        break (x, seen.val.unwrap(), seen_attrs.val)
      }
      Err(e) => {
        let d = match self.retry {
          None => @retry.Decision::Stop(NotRetryable)
          Some(dec) =>
            dec.decide(e, {
              request: raw,
              bucket,
              attempt: n,
              random: (self.random)(),
              now_unix_ms: now,
              remaining_ms: self.total_ms.map(t => t.to_int64() - (now - start)),
              replayable,
            })
        }
        if self.observer is Some(o) {
          o({ request: raw.head(), bucket, attempt: n, status, headers, duration_ms: now - t0, error: Some(e), decision: Some(d) })
        }
        match d {
          Wait(ms) => self.clock.sleep(ms)
          Stop(_) => raise e
        }
      }
    }
  }
  let body = match ex {
    Done(v) => v
    Pending(resp) => {
      defer resp.close()
      (r.response_as.read)(head, resp.body, { ..r.options, body_deadline: false })
    }
  }
  { status: head.status, headers: head.headers, body, request: raw.head(), attributes }
}

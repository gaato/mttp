///|
/// The default body limit of a Client: 64 MiB.
let default_max_body_bytes : Int32 = 64 * 1024 * 1024

///|
/// The deadlines and the body limit one request is sent under: the Client's,
/// with the plan's overrides applied field by field.
priv struct Limits {
  timeout_ms : Int32?
  max_body_bytes : Int32
  read_idle_ms : Int32?
}

///|
/// A backend plus shared request defaults, policies and injected timing
/// services. `Client::send` is the only sending path: it applies the
/// defaults, admission, deadlines, decoded-body limits, redirects, cookies
/// and retries, and maps each plan onto the `SendOptions` the backend
/// receives.
pub struct Client {
  /// The backend as the Client sends through it: wrapped in `Cookies` when
  /// a jar was given and in `FollowRedirects` unless redirects are off.
  priv backend : &@mttp.Backend
  priv clock : &@rt.Clock
  priv base_url : String
  priv headers : @mttp.Headers
  priv limits : Limits
  priv timer : &@rt.Timer?
  priv retry : RetryPolicy
  priv retry_budget : RetryBudget
  priv limiter : &RateLimiter
  priv total_ms : Int32?
  priv observer : (Attempt) -> Unit
  priv random : () -> Double
  priv mut closed : Bool
}

///|
/// Creates a client over `backend`, reading time from `clock`.
///
/// - `base_url` is prefixed to each request URL with `@mttp.join_url` (a
///   prefix join, never RFC 3986 resolution); `headers` are defaults, and a
///   header the request sets itself wins.
/// - `timeout_ms` is the attempt deadline, sent as `SendOptions.timeout_ms`.
/// - `max_body_bytes` (default 64 MiB) bounds the decoded bytes a buffered
///   reader keeps, and is sent as `Exchange(max_bytes)` for a Buffered plan,
///   so the backend bounds the wire bytes with the same number.
/// - `read_idle_ms` is the per-read deadline sent as `Stream(idle_ms)` for a
///   Streaming plan.
/// - `timer` lets the Client enforce deadlines itself: the attempt deadline
///   around each attempt (for backends that cannot, and for a buffered read
///   that a Streaming plan selects from the head), and the whole-call
///   `total_ms`, which requires it.
/// - `retry` (default: none), `limiter` (default: admits at once),
///   `observer` (gets one `Attempt` per attempt) and `random` (for jitter).
/// - `retry_budget` caps the retries of all sends at a share of recent
///   requests (default: `RetryBudget::new()`, 20 % plus 10 per second over
///   10 s). It is checked when a retry is decided, and a retry it refuses
///   stops with `RetryBudgetSpent`; it is charged when the retry is sent, and
///   a retry whose budget ran out during its wait returns the last outcome.
/// - `redirect` (default: `RedirectConfig::default()`, up to 10 hops) says
///   how redirects are followed. They are followed inside one attempt: the
///   limiter admits the attempt once, the attempt deadline covers every hop,
///   and a retry resends the original request, so a 503 on the second hop
///   starts the chain again. A request overrides the limit with
///   `RequestPlan::follow_redirects` and `max_redirects`.
///   `RedirectConfig::none()` (any `max_redirects` of 0 or less) turns
///   redirects off for the whole Client: it adds no redirect layer, returns
///   every 3xx as the backend gave it, and leaves the per-request limit to
///   the backend. Pass it when `backend` already contains `FollowRedirects`,
///   so redirects are not followed twice and that wrapper's
///   `redirect_history` and `final_url` reach the reply.
/// - `cookies` (default: none kept): a caller-owned `@cookie.CookieJar`. The
///   Client attaches its matching cookies to every request and redirect hop
///   and stores every response's `Set-Cookie` before the next hop.
pub fn Client::new(
  backend : &@mttp.Backend,
  clock : &@rt.Clock,
  base_url~ : String = "",
  headers~ : @mttp.Headers = @mttp.Headers::empty(),
  timeout_ms? : Int32,
  max_body_bytes~ : Int32 = default_max_body_bytes,
  read_idle_ms? : Int32,
  timer? : &@rt.Timer,
  retry~ : RetryPolicy = RetryPolicy::none(),
  retry_budget~ : RetryBudget = RetryBudget::new(),
  limiter~ : &RateLimiter = NoLimiter::new(),
  redirect~ : RedirectConfig = RedirectConfig::default(),
  cookies? : @cookie.CookieJar,
  total_ms? : Int32,
  observer~ : (Attempt) -> Unit = _ => (),
  random~ : () -> Double = @rt.default_random,
) -> Client {
  // The jar sits inside the redirects, so each hop sends the cookies for its
  // own URL and stores what it receives before the next hop.
  let backend : &@mttp.Backend = match cookies {
    Some(jar) => @cookies.Cookies::new(backend, jar) as &@mttp.Backend
    None => backend
  }
  let backend : &@mttp.Backend = if redirect.max_redirects > 0 {
    FollowRedirects::new(backend, config=redirect) as &@mttp.Backend
  } else {
    backend
  }
  {
    backend,
    clock,
    base_url,
    headers,
    limits: { timeout_ms, max_body_bytes, read_idle_ms, },
    timer,
    retry,
    retry_budget,
    limiter,
    total_ms,
    observer,
    random,
    closed: false,
  }
}

///|
/// Closes the shared backend idempotently and stops retries. A planned retry
/// returns its last outcome if closed before its wait or when that wait wakes,
/// without another limiter acquisition. Closing does not interrupt Clock.sleep.
/// Later sends fail with Closed in phase Pool before admission.
pub fn Client::close(self : Client) -> Unit {
  if !self.closed {
    self.closed = true
    self.backend.close()
  }
}

///|
fn Client::prepare(
  self : Client,
  request : @mttp.Request,
) -> @mttp.Request raise @mttp.TransportError {
  request.validate()
  let mut headers = @mttp.Headers::empty()
  for (name, value) in self.headers.iter() {
    if !request.headers.contains(name) {
      headers = headers.add(name, value)
    }
  }
  for (name, value) in request.headers.iter() {
    headers = headers.add(name, value)
  }
  let request = {
    ..request,
    url: @mttp.join_url(self.base_url, request.url),
    headers,
  }
  request.validate()
  request
}

///|
/// Refuses limits no attempt can honour, before admission: a negative body
/// limit or a nonpositive idle limit is `Invalid` in phase Pool.
fn validate_limits(limits : Limits) -> Unit raise @mttp.TransportError {
  if limits.max_body_bytes < 0 {
    raise @mttp.TransportError(
      kind=Invalid,
      phase=Pool,
      detail="negative body byte limit",
    )
  }
  if limits.read_idle_ms is Some(ms) && ms <= 0 {
    raise @mttp.TransportError(
      kind=Invalid,
      phase=Pool,
      detail="the idle read limit is not positive",
    )
  }
}

///|
/// What the backend is asked to do with the body. A Buffered plan is read
/// inside the attempt, so the deadline covers it and the wire is capped; a
/// Streaming plan, `from_head` included, may hand the body to a consumer
/// after the attempt, so the deadline ends at the head and each read gets
/// the idle limit.
fn body_timing(streaming : Bool, limits : Limits) -> @mttp.BodyTiming {
  if streaming {
    Stream(idle_ms=limits.read_idle_ms)
  } else {
    Exchange(max_bytes=limits.max_body_bytes)
  }
}

///|
priv enum ReadResult[T] {
  Buffered(T, @mttp.Response)
  Streaming(@mttp.Response, Selected[T])
}

///|
fn timeout(ms : Int32) -> @mttp.TransportError {
  @mttp.TransportError(
    kind=Timeout(ms~),
    phase=Unknown,
    detail="attempt deadline expired",
  )
}

///|
/// One attempt's exchange: send, capture the head, and read a buffered
/// branch, including one a Streaming plan selected from the head. A
/// selected stream is handed back unread.
async fn[T, M] Client::exchange(
  self : Client,
  request : @mttp.Request,
  reader : ResponsePlan[T, M],
  options : @mttp.SendOptions,
  limit : Int32,
  received : Ref[@mttp.ResponseHead?],
) -> ReadResult[T] {
  let started = self.clock.now_unix_ms()
  let response = self.backend.send(request, options)
  received.val = Some(response.head())
  let mut transferred = false
  defer (if !transferred { response.close() })
  if options.timeout_ms is Some(ms) &&
    self.clock.now_unix_ms() - started >= ms.to_int64() {
    raise timeout(ms)
  }
  let head = response.head()
  let selected = (reader.select)(head, reader.any_status)
  let selected = match selected.prepare {
    Some(prepare) => prepare(head, response.body, limit)
    None => selected
  }
  if options.timeout_ms is Some(ms) &&
    self.clock.now_unix_ms() - started >= ms.to_int64() {
    raise timeout(ms)
  }
  if selected.streaming {
    transferred = true
    return Streaming(response, selected)
  }
  let body = (selected.read)(head, response.body, limit)
  if options.timeout_ms is Some(ms) &&
    self.clock.now_unix_ms() - started >= ms.to_int64() {
    raise timeout(ms)
  }
  Buffered(body, response)
}

///|
/// Sends a typed description through the one executor.
///
/// Before admission, the request and its limits are validated, and a total
/// deadline requires a Timer. Each attempt acquires the limiter, builds the
/// body (`body_fn` runs after admission), sends with `SendOptions` mapped
/// from the plan, captures the head and reads a buffered branch; it then
/// releases the limiter with that head, reports one `Attempt` and asks the
/// retry policy (or `decide_retry`, which also sees the policy's default
/// decision). A selected stream consumer starts only after that, and its
/// result or exception is never retried.
/// Closing the client stops a planned retry before sleeping or, if already
/// asleep, on waking, and returns the last attempt's reply or raised error.
#warnings("-fragile_catch_all")
pub async fn[T, M : ResponseMode] Client::send(
  self : Client,
  request : RequestPlan[T, M],
  decide_retry? : (AttemptResult[T], RetryContext) -> Decision,
) -> Reply[T] {
  let started = self.clock.now_unix_ms()
  self.check_total(started)
  match self.total_ms {
    None => self.send_loop(request, started, decide_retry?)
    Some(ms) => {
      let timer = match self.timer {
        Some(timer) => timer
        None =>
          raise InvalidRequest(message="a total deadline requires a Timer")
      }
      let result : Ref[Result[Reply[T], Error]?] = Ref(None)
      // Capture ordinary failures as data across the Timer's noraise callback.
      // Cancellation bypasses this catch and still unwinds the owned bodies.
      let completed = timer.within(ms, () => {
        result.val = Some(
          Ok(self.send_loop(request, started, decide_retry?)) catch {
            error => Err(error)
          },
        )
      })
      match result.val {
        Some(Ok(reply)) => reply
        Some(Err(error)) => raise error
        None if !completed => raise timeout(ms)
        None =>
          raise InvalidRequest(
            message="timer completed without running its callback",
          )
      }
    }
  }
}

///|
/// The errdefer releases the limiter slot and observes the attempt after a
/// cancellation. This runtime-free module cannot shield cleanup from
/// cancellation itself; the host's limiter implementations are responsible
/// for making release cancellation-safe.
#warnings("-fragile_catch_all-cancellable_defer")
async fn[T, M : ResponseMode] Client::send_loop(
  self : Client,
  request : RequestPlan[T, M],
  started : Int64,
  decide_retry? : (AttemptResult[T], RetryContext) -> Decision,
) -> Reply[T] {
  let raw = self.prepare(request.wire())
  let limits = request.limits(self.limits)
  validate_limits(limits)
  let body = body_timing(
    ResponseMode::may_stream(request.response_as.mode),
    limits,
  )
  let bucket = raw.attributes.get(rate_limit_bucket).unwrap_or("default")
  let exempt = raw.attributes.get(global_exempt).unwrap_or(false)
  let replayable = request.body_factory is Some(_) ||
    raw.body is (Empty | Bytes(_))
  self.retry_budget.deposit(self.clock.now_unix_ms())
  for attempt = 0; ; attempt = attempt + 1 {
    if self.closed {
      raise @mttp.TransportError(
        kind=Closed,
        phase=Pool,
        detail="client closed",
      )
    }
    self.check_total(started)
    let admission = self.limiter.acquire(bucket, global_exempt=exempt)
    let received = Ref(None)
    let attempt_started = self.clock.now_unix_ms()
    let mut releasing = false
    let mut settled = false
    let mut sent = raw
    let mut held : ReadResult[T]? = None
    errdefer {
      defer (if !settled {
        (self.observer)(
          attempt_info(
            sent,
            bucket,
            attempt,
            received.val,
            self.clock.now_unix_ms() - attempt_started,
            None,
            None,
          ),
        )
      })
      if held is Some(value) {
        discard(value)
      }
      if !releasing {
        self.release_cancelled(admission, received.val)
      }
    }
    let options : @mttp.SendOptions = {
      timeout_ms: self.budget(limits.timeout_ms, started),
      body,
    }
    // This catch exists for release/observation and preserves exception identity.
    // Only TransportError is later offered to retry policy.
    let outcome : Result[ReadResult[T], Error] = try {
      self.check_total(started)
      if options.timeout_ms is Some(ms) && ms <= 0 {
        raise timeout(ms)
      }
      sent = match request.body_factory {
        Some(factory) => raw.body_bytes(factory())
        None => raw
      }
      self.exchange_timed(
        sent,
        request.response_as,
        options,
        limits.max_body_bytes,
        received,
      )
    } catch {
      error => Err(error)
    } noraise {
      value => Ok(value)
    }
    if outcome is Ok(value) {
      held = Some(value)
    }
    releasing = true
    self.limiter.release(
      admission,
      status=received.val.map(h => h.status).unwrap_or(0),
      headers=received.val.map(h => h.headers).unwrap_or(@mttp.Headers::empty()),
    ) catch {
      error =>
        if outcome is Ok(_) {
          settled = true
          (self.observer)(
            attempt_info(
              sent,
              bucket,
              attempt,
              received.val,
              self.clock.now_unix_ms() - attempt_started,
              Some(error),
              None,
            ),
          )
          raise error
        }
    }
    let event : AttemptResult[T] = match outcome {
      Ok(Buffered(body, response)) => Buffered(reply_of(sent, body, response))
      Ok(Streaming(response, _)) => StreamReady(response.head())
      Err(@mttp.TransportError(..) as error) => TransportFailure(error)
      Err(error) => {
        settled = true
        (self.observer)(
          attempt_info(
            sent,
            bucket,
            attempt,
            received.val,
            self.clock.now_unix_ms() - attempt_started,
            Some(error),
            None,
          ),
        )
        raise error
      }
    }
    let context = RetryContext::new(
      raw.head(),
      idempotent=@mttp.is_idempotent(raw),
      replayable~,
      bucket~,
      attempt~,
      random=(self.random)(),
      now_unix_ms=self.clock.now_unix_ms(),
      remaining_ms?=self.remaining(started),
    )
    let default_decision = self.retry.decide(event.http_outcome(), context)
    let context = { ..context, default_decision, }
    let proposed = match decide_retry {
      Some(decide) => decide(event, context)
      None => default_decision
    }
    let decision = self.guard_retry(proposed, context)
    let error : Error? = match outcome {
      Err(error) => Some(error)
      _ => None
    }
    let observed_decision = if error is Some(_) ||
      (received.val is Some(head) && !@mttp.is_success(head.status)) ||
      decide_retry is Some(_) {
      Some(decision)
    } else {
      None
    }
    settled = true
    (self.observer)(
      attempt_info(
        sent,
        bucket,
        attempt,
        received.val,
        self.clock.now_unix_ms() - attempt_started,
        error,
        observed_decision,
      ),
    )
    match decision {
      Wait(ms) if !self.closed => {
        self.clock.sleep(ms)
        // Keep the outcome until the wait finishes: close must return the
        // same reply (including a selected stream) as Stop would have. The
        // retry budget is charged now, when the retry is sent; if it was
        // spent during the wait, the send ends with this outcome too.
        if !self.closed &&
          self.retry_budget.try_withdraw(self.clock.now_unix_ms()) {
          if held is Some(value) {
            discard(value)
          }
          held = None
          continue
        }
      }
      _ => ()
    }
    self.check_total(started)
    match outcome {
      Err(error) => raise error
      Ok(Buffered(body, response)) => {
        held = None
        return reply_of(sent, body, response)
      }
      Ok(Streaming(response, selected)) => {
        defer response.close()
        // No retry boundary encloses this consumer, including its errors.
        let body = (selected.read)(
          response.head(),
          response.body,
          limits.max_body_bytes,
        )
        self.check_total(started)
        held = None
        return reply_of(sent, body, response)
      }
    }
  }
}

///|
fn Client::guard_retry(
  self : Client,
  proposed : Decision,
  context : RetryContext,
) -> Decision {
  match proposed {
    Stop(_) => proposed
    Wait(_) if context.attempt >= self.retry.rule.max_retries => Stop(Exhausted)
    Wait(_) if !context.replayable => Stop(NotReplayable)
    Wait(ms) => {
      let ms = ms.max(0)
      if context.remaining_ms is Some(left) && ms.to_int64() >= left {
        Stop(Budget(ms))
      } else if !self.retry_budget.allows(self.clock.now_unix_ms()) {
        Stop(RetryBudgetSpent)
      } else {
        Wait(ms)
      }
    }
    Decision::.. => Stop(NotRetryable)
  }
}

///|
fn[T] reply_of(
  request : @mttp.Request,
  body : T,
  response : @mttp.Response,
) -> Reply[T] {
  {
    status: response.status,
    headers: response.headers,
    body,
    request: request.head(),
    attributes: response.attributes,
  }
}

///|
/// The exchange inside the Client's own attempt deadline when it has a
/// Timer: the deadline the backend got, measured from the attempt's start,
/// so a buffered read selected after a `Stream` head keeps the remainder.
async fn[T, M] Client::exchange_timed(
  self : Client,
  raw : @mttp.Request,
  reader : ResponsePlan[T, M],
  options : @mttp.SendOptions,
  limit : Int32,
  received : Ref[@mttp.ResponseHead?],
) -> ReadResult[T] {
  match (self.timer, options.timeout_ms) {
    (Some(timer), Some(ms)) => {
      let mut result : Result[ReadResult[T], Error]? = None
      errdefer (if result is Some(Ok(value)) { discard(value) })
      let complete = timer.within(ms, () => {
        result = Some(
          Ok(self.exchange(raw, reader, options, limit, received)) catch {
            error => Err(error)
          },
        )
      })
      match result {
        Some(Ok(value)) => value
        Some(Err(error)) => raise error
        None if !complete => raise timeout(ms)
        None =>
          raise @mttp.TransportError(
            kind=Protocol,
            phase=Unknown,
            detail="timer completed without running callback",
          )
      }
    }
    _ => self.exchange(raw, reader, options, limit, received)
  }
}

///|
fn[T] discard(value : ReadResult[T]) -> Unit {
  match value {
    Buffered(_, response) | Streaming(response, _) => response.close()
  }
}

///|
fn Client::remaining(self : Client, started : Int64) -> Int64? {
  self.total_ms.map(total => {
    total.to_int64() - (self.clock.now_unix_ms() - started).max(0L)
  })
}

///|
fn Client::check_total(
  self : Client,
  started : Int64,
) -> Unit raise @mttp.TransportError {
  if self.remaining(started) is Some(left) && left <= 0L {
    raise timeout(self.total_ms.unwrap())
  }
}

///|
fn Client::budget(
  self : Client,
  per_attempt : Int32?,
  started : Int64,
) -> Int32? {
  match self.remaining(started) {
    None => per_attempt
    Some(left) => {
      let left = left.max(0L).min(2147483647L).to_int()
      Some(per_attempt.map(ms => ms.min(left)).unwrap_or(left))
    }
  }
}

///|
async fn Client::release_cancelled(
  self : Client,
  admission : Admission,
  head : @mttp.ResponseHead?,
) -> Unit noraise {
  self.limiter.release(
    admission,
    status=head.map(h => h.status).unwrap_or(0),
    headers=head.map(h => h.headers).unwrap_or(@mttp.Headers::empty()),
  ) catch {
    _ => ()
  }
}

///|
fn attempt_info(
  request : @mttp.Request,
  bucket : String,
  attempt : Int32,
  head : @mttp.ResponseHead?,
  duration_ms : Int64,
  error : Error?,
  decision : @retry.Decision?,
) -> Attempt {
  {
    request: request.head(),
    attributes: request.attributes,
    bucket,
    attempt,
    status: head.map(h => h.status).unwrap_or(0),
    headers: head.map(h => h.headers).unwrap_or(@mttp.Headers::empty()),
    duration_ms,
    error,
    decision,
  }
}

///|
/// Pairs a wire request with a UTF-8 string reader accepting successful statuses.
pub fn request(
  raw : @mttp.Request,
) -> ClientRequest[Result[String, ResponseFailure]] {
  ClientRequest::new(raw, as_string())
}

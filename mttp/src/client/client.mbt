///|
/// A backend plus shared request defaults and injected timing services.
pub struct Client {
  priv backend : &Backend
  priv clock : &@clock.Clock
  priv base_url : String
  priv headers : @model.Headers
  priv options : RequestOptions
  priv timer : &@clock.Timer?
  priv retry : RetryPolicy
  priv limiter : &RateLimiter
  priv total_ms : Int32?
  priv observer : (Attempt) -> Unit
  priv random : () -> Double
}

///|
/// Creates a client with explicit transport and clock. A timer can enforce
/// deadlines for in-process backends that cannot do so themselves.
pub fn Client::new(
  backend : &Backend,
  clock : &@clock.Clock,
  base_url~ : String = "",
  headers~ : @model.Headers = @model.Headers::empty(),
  options~ : RequestOptions = RequestOptions::default(),
  timer? : &@clock.Timer,
  retry~ : RetryPolicy = RetryPolicy::none(),
  limiter~ : &RateLimiter = NoLimiter::new(),
  total_ms? : Int32,
  observer~ : (Attempt) -> Unit = _ => (),
  random~ : () -> Double = @clock.default_random,
) -> Client {
  {
    backend,
    clock,
    base_url,
    headers,
    options,
    timer,
    retry,
    limiter,
    total_ms,
    observer,
    random,
  }
}

///|
/// Closes the shared backend. Its close operation is idempotent.
pub fn Client::close(self : Client) -> Unit {
  self.backend.close()
}

///|
fn Client::prepare(
  self : Client,
  request : @model.Request,
) -> @model.Request raise @model.TransportError {
  request.validate()
  let mut headers = @model.Headers::empty()
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
    url: @model.join_url(self.base_url, request.url),
    headers,
  }
  request.validate()
  request
}

///|
priv enum ReadResult[T] {
  Buffered(T, @model.Response)
  Streaming(@model.Response, Selected[T])
}

///|
fn timeout(ms : Int32) -> @model.TransportError {
  @model.TransportError(
    kind=Timeout(ms~),
    phase=Unknown,
    detail="attempt deadline expired",
  )
}

///|
async fn[T, M] Client::exchange(
  self : Client,
  request : @model.Request,
  reader : ResponsePlan[T, M],
  options : RequestOptions,
  received : Ref[@model.ResponseHead?],
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
  if selected.streaming {
    transferred = true
    return Streaming(response, selected)
  }
  let body = (selected.read)(head, response.body, options)
  if options.timeout_ms is Some(ms) &&
    self.clock.now_unix_ms() - started >= ms.to_int64() {
    raise timeout(ms)
  }
  Buffered(body, response)
}

///|
/// Sends a typed description through one executor. A total deadline needs a
/// Timer so admission and user stream processing can actually be cancelled.
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
#warnings("-fragile_catch_all")
async fn[T, M : ResponseMode] Client::send_loop(
  self : Client,
  request : RequestPlan[T, M],
  started : Int64,
  decide_retry? : (AttemptResult[T], RetryContext) -> Decision,
) -> Reply[T] {
  let raw = self.prepare(request.raw)
  let defaults = {
    ..request.options(self.options),
    body_deadline: !ResponseMode::may_stream(request.response_as.mode),
  }
  let bucket = raw.attributes.get(rate_limit_bucket).unwrap_or("default")
  let exempt = raw.attributes.get(global_exempt).unwrap_or(false)
  let replayable = request.body_factory is Some(_) ||
    raw.body is (Empty | Bytes(_))
  for attempt = 0; ; attempt = attempt + 1 {
    self.check_total(started)
    self.limiter.acquire(bucket, global_exempt=exempt)
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
        self.release_cancelled(bucket, received.val)
      }
    }
    let options = {
      ..defaults,
      timeout_ms: self.budget(defaults.timeout_ms, started),
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
      self.exchange_timed(sent, request.response_as, options, received)
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
      bucket,
      status=received.val.map(h => h.status).unwrap_or(0),
      headers=received.val
        .map(h => h.headers)
        .unwrap_or(@model.Headers::empty()),
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
      Err(@model.TransportError(..) as error) => TransportFailure(error)
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
      idempotent=@model.is_idempotent(raw),
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
      (received.val is Some(head) && !@model.is_success(head.status)) ||
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
      Wait(ms) => {
        if held is Some(value) {
          discard(value)
        }
        held = None
        self.clock.sleep(ms)
      }
      Stop(_) | Decision::.. => {
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
            let body = (selected.read)(response.head(), response.body, options)
            self.check_total(started)
            held = None
            return reply_of(sent, body, response)
          }
        }
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
      } else {
        Wait(ms)
      }
    }
    Decision::.. => Stop(NotRetryable)
  }
}

///|
fn[T] reply_of(
  request : @model.Request,
  body : T,
  response : @model.Response,
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
async fn[T, M] Client::exchange_timed(
  self : Client,
  raw : @model.Request,
  reader : ResponsePlan[T, M],
  options : RequestOptions,
  received : Ref[@model.ResponseHead?],
) -> ReadResult[T] {
  match (self.timer, options.timeout_ms) {
    (Some(timer), Some(ms)) => {
      let mut result : Result[ReadResult[T], Error]? = None
      errdefer (if result is Some(Ok(value)) { discard(value) })
      let complete = timer.within(ms, () => {
        result = Some(
          Ok(self.exchange(raw, reader, options, received)) catch {
            error => Err(error)
          },
        )
      })
      match result {
        Some(Ok(value)) => value
        Some(Err(error)) => raise error
        None if !complete => raise timeout(ms)
        None =>
          raise @model.TransportError(
            kind=Protocol,
            phase=Unknown,
            detail="timer completed without running callback",
          )
      }
    }
    _ => self.exchange(raw, reader, options, received)
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
) -> Unit raise @model.TransportError {
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
  bucket : String,
  head : @model.ResponseHead?,
) -> Unit noraise {
  self.limiter.release(
    bucket,
    status=head.map(h => h.status).unwrap_or(0),
    headers=head.map(h => h.headers).unwrap_or(@model.Headers::empty()),
  ) catch {
    _ => ()
  }
}

///|
fn attempt_info(
  request : @model.Request,
  bucket : String,
  attempt : Int32,
  head : @model.ResponseHead?,
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
    headers: head.map(h => h.headers).unwrap_or(@model.Headers::empty()),
    duration_ms,
    error,
    decision,
  }
}

///|
/// Pairs a wire request with a UTF-8 string reader accepting successful statuses.
pub fn request(
  raw : @model.Request,
) -> ClientRequest[Result[String, ResponseFailure]] {
  ClientRequest::new(raw, as_string())
}

///|
/// Pairs a wire request with a UTF-8 string reader accepting every HTTP status.
pub fn quick_request(
  raw : @model.Request,
) -> ClientRequest[Result[String, ResponseFailure]] {
  ClientRequest::new(raw, as_string().any_status())
}

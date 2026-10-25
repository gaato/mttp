///|
/// A backend plus shared request defaults and injected timing services.
pub struct Client {
  priv backend : &Backend
  priv clock : &@clock.Clock
  priv base_url : String
  priv headers : @model.Headers
  priv options : RequestOptions
  priv timer : &@clock.Timer?
  priv retry : &RetryDecider
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
  retry~ : &RetryDecider = RetryPolicy::none(),
  limiter~ : &RateLimiter = NoLimiter::new(),
  total_ms? : Int32,
  observer~ : (Attempt) -> Unit = _ => (),
  random~ : () -> Double = () => 0.5,
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
async fn[T] Client::exchange(
  self : Client,
  request : @model.Request,
  reader : ResponseAs[T],
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
  let selected = (reader.select)(head)
  if !selected.accept {
    let body = error_excerpt(response.body)
    (selected.reject)(head, body)
    raise UnexpectedStatus(head, body~)
  }
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
/// Sends with merged defaults and decodes the response. Accepted streaming
/// callbacks run after the head exchange and own the body until they return.
/// Cancellation is settled by errdefer; the catch reports the actual release
/// error, which cannot be obtained in a cancellation-only cleanup.
#warnings("-fragile_catch_all")
pub async fn[T] Client::send(
  self : Client,
  request : ClientRequest[T],
) -> Reply[T] {
  let raw = self.prepare(request.raw)
  let defaults = {
    ..request.options(self.options),
    body_deadline: !request.response_as.streaming,
  }
  let started = self.clock.now_unix_ms()
  let bucket = raw.attributes.get(rate_limit_bucket).unwrap_or("default")
  let exempt = raw.attributes.get(global_exempt).unwrap_or(false)
  // A stream has no replay source even when a backend failed before taking
  // it. Only an explicit factory can opt into rebuilding an outgoing body.
  let replayable = request.body_factory is Some(_) || !(raw.body is Stream(_))
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
    // Do not retry an admission service's own release failure. In
    // particular, retrying cannot repair a partly released admission.
    self.limiter.release(
      bucket,
      status=received.val.map(h => h.status).unwrap_or(0),
      headers=received.val
        .map(h => h.headers)
        .unwrap_or(@model.Headers::empty()),
    ) catch {
      error =>
        // Preserve the exchange error on an already failing attempt, as in
        // sdk-runtime. A release error only replaces a successful outcome.
        if outcome is Err(_) {
          ()
        } else {
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
    match outcome {
      Ok(value) => {
        settled = true
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
        let (body, response) = match value {
          Buffered(body, response) => (body, response)
          Streaming(response, selected) => {
            defer response.close()
            ((selected.read)(response.head(), response.body, options), response)
          }
        }
        held = None
        return {
          status: response.status,
          headers: response.headers,
          body,
          request: sent.head(),
          attributes: response.attributes,
        }
      }
      Err(error) => {
        let context = RetryContext::new(
          raw,
          bucket~,
          attempt~,
          random=(self.random)(),
          now_unix_ms=self.clock.now_unix_ms(),
          remaining_ms?=self.remaining(started),
          replayable~,
        )
        let decision = match self.retry.decide(error, context) {
          Wait(_) if !replayable => @retry.Decision::Stop(NotReplayable)
          decision => decision
        }
        settled = true
        (self.observer)(
          attempt_info(
            sent,
            bucket,
            attempt,
            received.val,
            self.clock.now_unix_ms() - attempt_started,
            Some(error),
            Some(decision),
          ),
        )
        match decision {
          Stop(_) => raise error
          Wait(ms) => self.clock.sleep(ms)
        }
      }
    }
  }
}

///|
async fn[T] Client::exchange_timed(
  self : Client,
  raw : @model.Request,
  reader : ResponseAs[T],
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
pub fn request(raw : @model.Request) -> ClientRequest[String] {
  ClientRequest::new(raw, as_string())
}

///|
/// Pairs a wire request with a UTF-8 string reader accepting every HTTP status.
pub fn quick_request(raw : @model.Request) -> ClientRequest[String] {
  ClientRequest::new(raw, as_string().any_status())
}

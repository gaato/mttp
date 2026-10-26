///|
/// A wire request, response description and per-request options.
pub struct RequestPlan[T, M] {
  priv raw : @model.Request
  priv response_as : ResponsePlan[T, M]
  priv body_factory : (() -> Bytes)?
  priv timeout : Int32?
  priv idle : Int32?
  priv body_limit : Int32?
  priv redirects : Bool?
  priv redirect_limit : Int32?
}

///|
/// A request whose response is buffered before it is returned.
pub type ClientRequest[T] = RequestPlan[T, Buffered]

///|
/// A request whose response may run a scoped stream consumer.
pub type StreamRequest[T] = RequestPlan[T, Streaming]

///|
/// Pairs a wire request with its response interpretation.
pub fn[T, M] RequestPlan::new(
  raw : @model.Request,
  response_as : ResponsePlan[T, M],
) -> RequestPlan[T, M] {
  {
    raw,
    response_as,
    body_factory: None,
    timeout: None,
    idle: None,
    body_limit: None,
    redirects: None,
    redirect_limit: None,
  }
}

///|
/// Replaces the interpretation, including its lifetime marker.
pub fn[T, U, M, N] RequestPlan::response(
  self : RequestPlan[T, M],
  response_as : ResponsePlan[U, N],
) -> RequestPlan[U, N] {
  {
    raw: self.raw,
    response_as,
    body_factory: self.body_factory,
    timeout: self.timeout,
    idle: self.idle,
    body_limit: self.body_limit,
    redirects: self.redirects,
    redirect_limit: self.redirect_limit,
  }
}

///|
/// Supplies bytes freshly built after admission on each attempt.
pub fn[T, M] RequestPlan::body_fn(
  self : RequestPlan[T, M],
  factory : () -> Bytes,
) -> RequestPlan[T, M] {
  { ..self, body_factory: Some(factory), }
}

///|
/// Adds a wire header to a copy of the request.
pub fn[T, M] RequestPlan::header(
  self : RequestPlan[T, M],
  name : String,
  value : String,
) -> RequestPlan[T, M] {
  { ..self, raw: self.raw.header(name, value), }
}

///|
/// Sets a bearer Authorization header on a copy.
pub fn[T, M] RequestPlan::bearer(
  self : RequestPlan[T, M],
  token : String,
) -> RequestPlan[T, M] {
  { ..self, raw: self.raw.bearer(token), }
}

///|
/// Sets a replayable byte body on a copy.
pub fn[T, M] RequestPlan::body_bytes(
  self : RequestPlan[T, M],
  bytes : Bytes,
) -> RequestPlan[T, M] {
  { ..self, raw: self.raw.body_bytes(bytes), body_factory: None, }
}

///|
/// Sets a JSON body on a copy.
pub fn[T, M] RequestPlan::body_json(
  self : RequestPlan[T, M],
  value : Json,
) -> RequestPlan[T, M] {
  { ..self, raw: self.raw.body_json(value), body_factory: None, }
}

///|
/// Overrides the attempt timeout while retaining other options.
pub fn[T, M] RequestPlan::timeout_ms(
  self : RequestPlan[T, M],
  ms : Int32,
) -> RequestPlan[T, M] {
  { ..self, timeout: Some(ms), }
}

///|
/// Overrides the stream read-idle timeout.
pub fn[T, M] RequestPlan::read_idle_ms(
  self : RequestPlan[T, M],
  ms : Int32,
) -> RequestPlan[T, M] {
  { ..self, idle: Some(ms), }
}

///|
/// Overrides the buffered-body bound.
pub fn[T, M] RequestPlan::max_body_bytes(
  self : RequestPlan[T, M],
  bytes : Int32,
) -> RequestPlan[T, M] {
  { ..self, body_limit: Some(bytes), }
}

///|
/// Adds typed local metadata to a copy.
pub fn[T, A, M] RequestPlan::attribute(
  self : RequestPlan[T, M],
  key : @model.AttributeKey[A],
  value : A,
) -> RequestPlan[T, M] {
  { ..self, raw: self.raw.attribute(key, value), }
}

///|
/// Returns the wire request before client defaults are applied.
pub fn[T, M] RequestPlan::raw(self : RequestPlan[T, M]) -> @model.Request {
  self.raw
}

///|
fn[T, M] RequestPlan::options(
  self : RequestPlan[T, M],
  defaults : RequestOptions,
) -> RequestOptions {
  {
    ..defaults,
    timeout_ms: match self.timeout {
      Some(ms) => Some(ms)
      None => defaults.timeout_ms
    },
    read_idle_ms: match self.idle {
      Some(ms) => Some(ms)
      None => defaults.read_idle_ms
    },
    max_body_bytes: self.body_limit.unwrap_or(defaults.max_body_bytes),
    follow_redirects: self.redirects.unwrap_or(defaults.follow_redirects),
    max_redirects: self.redirect_limit.unwrap_or(defaults.max_redirects),
  }
}

///|
/// Overrides redirect following.
pub fn[T, M] RequestPlan::follow_redirects(
  self : RequestPlan[T, M],
  enabled : Bool,
) -> RequestPlan[T, M] {
  { ..self, redirects: Some(enabled), }
}

///|
/// Overrides the redirect-hop limit.
pub fn[T, M] RequestPlan::max_redirects(
  self : RequestPlan[T, M],
  max : Int32,
) -> RequestPlan[T, M] {
  { ..self, redirect_limit: Some(max), }
}

///|
/// Sends through the Client's single executor, with an optional typed policy.
pub async fn[T, M : ResponseMode] RequestPlan::send(
  self : RequestPlan[T, M],
  client : Client,
  decide_retry? : (AttemptResult[T], RetryContext) -> Decision,
) -> Reply[T] {
  client.send(self, decide_retry?)
}

///|
/// A decoded response, preserving the actual HTTP and request metadata.
pub(all) struct Reply[T] {
  status : Int32
  headers : @model.Headers
  body : T
  request : @model.RequestHead
  attributes : @model.Attributes
}

///|
/// An explicit local admission bucket; absent metadata selects "default".
pub let rate_limit_bucket : @model.AttributeKey[String] = @model.AttributeKey::new(
  "rate_limit_bucket",
)

///|
/// Whether the request bypasses global admission limits.
pub let global_exempt : @model.AttributeKey[Bool] = @model.AttributeKey::new(
  "global_exempt",
)

///|
/// The endpoint operation identifier, independent of admission buckets.
pub let operation_id : @model.AttributeKey[String] = @model.AttributeKey::new(
  "operation_id",
)

///|
/// Creates a GET request with the default Result-valued string reader.
pub fn get(url : String) -> ClientRequest[Result[String, ResponseFailure]] {
  request(@model.Request::get(url))
}

///|
/// Creates a POST request with the default Result-valued string reader.
pub fn post(url : String) -> ClientRequest[Result[String, ResponseFailure]] {
  request(@model.Request::post(url))
}

///|
/// A request paired with its response reader and individual option overrides.
pub struct ClientRequest[T] {
  priv raw : @model.Request
  priv response_as : ResponseAs[T]
  priv body_factory : (() -> Bytes)?
  priv timeout : Int32?
  priv idle : Int32?
  priv body_limit : Int32?
  priv redirects : Bool?
  priv redirect_limit : Int32?
}

///|
/// Pairs a wire request with its response interpretation.
pub fn[T] ClientRequest::new(
  raw : @model.Request,
  response_as : ResponseAs[T],
) -> ClientRequest[T] {
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
/// Replaces only the response interpretation.
pub fn[T, U] ClientRequest::response(
  self : ClientRequest[T],
  response_as : ResponseAs[U],
) -> ClientRequest[U] {
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
/// Supplies replayable bytes freshly built for each admitted attempt.
pub fn[T] ClientRequest::body_fn(
  self : ClientRequest[T],
  factory : () -> Bytes,
) -> ClientRequest[T] {
  { ..self, body_factory: Some(factory), }
}

///|
/// Overrides the attempt timeout without resetting other client defaults.
pub fn[T] ClientRequest::timeout_ms(
  self : ClientRequest[T],
  ms : Int32,
) -> ClientRequest[T] {
  { ..self, timeout: Some(ms), }
}

///|
/// Overrides the per-read idle timeout without resetting other defaults.
pub fn[T] ClientRequest::read_idle_ms(
  self : ClientRequest[T],
  ms : Int32,
) -> ClientRequest[T] {
  { ..self, idle: Some(ms), }
}

///|
/// Overrides the accepted buffered body limit.
pub fn[T] ClientRequest::max_body_bytes(
  self : ClientRequest[T],
  bytes : Int32,
) -> ClientRequest[T] {
  { ..self, body_limit: Some(bytes), }
}

///|
/// Adds typed local request metadata to a copy.
pub fn[T, A] ClientRequest::attribute(
  self : ClientRequest[T],
  key : @model.AttributeKey[A],
  value : A,
) -> ClientRequest[T] {
  { ..self, raw: self.raw.attribute(key, value), }
}

///|
/// Returns the original wire request without applying client defaults.
pub fn[T] ClientRequest::raw(self : ClientRequest[T]) -> @model.Request {
  self.raw
}

///|
fn[T] ClientRequest::options(
  self : ClientRequest[T],
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
/// Overrides redirect following without resetting other client defaults.
pub fn[T] ClientRequest::follow_redirects(
  self : ClientRequest[T],
  enabled : Bool,
) -> ClientRequest[T] {
  { ..self, redirects: Some(enabled), }
}

///|
/// Overrides the maximum number of followed redirect hops.
pub fn[T] ClientRequest::max_redirects(
  self : ClientRequest[T],
  max : Int32,
) -> ClientRequest[T] {
  { ..self, redirect_limit: Some(max), }
}

///|
/// A decoded response with the request metadata actually sent.
pub(all) struct Reply[T] {
  status : Int32
  headers : @model.Headers
  body : T
  request : @model.RequestHead
  attributes : @model.Attributes
}

///|
/// An explicit rate-limit bucket; the default bucket is "default".
pub let rate_limit_bucket : @model.AttributeKey[String] = @model.AttributeKey::new(
  "rate_limit_bucket",
)

///|
/// Whether a request is exempt from global rate-limit admission.
pub let global_exempt : @model.AttributeKey[Bool] = @model.AttributeKey::new(
  "global_exempt",
)

///|
/// Endpoint operation metadata, deliberately separate from rate-limit buckets.
pub let operation_id : @model.AttributeKey[String] = @model.AttributeKey::new(
  "operation_id",
)

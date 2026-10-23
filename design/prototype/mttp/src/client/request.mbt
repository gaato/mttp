///|
/// A request paired with how to read its response (sttp Request[T]).
/// Request shaping lives on @model.Request; defaults (base URL, headers,
/// auth) live in `Client`.
pub struct ClientRequest[T] {
  priv raw : @model.Request
  priv options : RequestOptions
  priv response_as : ResponseAs[T]
  priv body_fn : (() -> Bytes)?
}

///|
pub fn[T] ClientRequest::new(
  raw : @model.Request,
  response_as : ResponseAs[T],
  options? : RequestOptions = RequestOptions::default(),
) -> ClientRequest[T] {
  { raw, options, response_as, body_fn: None }
}

///|
pub fn[T] ClientRequest::raw(self : ClientRequest[T]) -> @model.Request {
  self.raw
}

///|
pub fn[T, U] ClientRequest::response(self : ClientRequest[T], ra : ResponseAs[U]) -> ClientRequest[U] {
  { raw: self.raw, options: self.options, response_as: ra, body_fn: self.body_fn }
}

///|
/// Built per attempt, after admission (sdk-runtime's body thunk); makes a
/// request replayable.
pub fn[T] ClientRequest::body_fn(self : ClientRequest[T], f : () -> Bytes) -> ClientRequest[T] {
  { ..self, body_fn: Some(f) }
}

///|
pub fn[T] ClientRequest::timeout_ms(self : ClientRequest[T], ms : Int) -> ClientRequest[T] {
  { ..self, options: { ..self.options, timeout_ms: Some(ms) } }
}

///|
pub fn[T] ClientRequest::max_body_bytes(self : ClientRequest[T], n : Int) -> ClientRequest[T] {
  { ..self, options: { ..self.options, max_body_bytes: n } }
}

///|
pub fn[T] ClientRequest::read_idle_ms(self : ClientRequest[T], ms : Int) -> ClientRequest[T] {
  { ..self, options: { ..self.options, read_idle_ms: Some(ms) } }
}

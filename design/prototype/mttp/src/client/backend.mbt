///|
/// Transport knobs, passed to every Backend::send. Frozen field set:
/// build with ::default() and record update.
pub(all) struct RequestOptions {
  timeout_ms : Int?        // attempt deadline from send until the head; with body_deadline, until the end of the body
  body_deadline : Bool     // set by Client::send: true for buffered readers (exchange deadline), false for streaming ones
  read_idle_ms : Int?      // per read on a streamed body (SSE idle timeout)
  max_body_bytes : Int     // buffered readers; 64 MiB
  follow_redirects : Bool  // honoured by FollowRedirects (v0.2)
  max_redirects : Int      // 10
  decompress : Bool        // the backend undoes content codings and sends its own Accept-Encoding
} derive(Eq, Debug)

///|
pub fn RequestOptions::default() -> RequestOptions {
  {
    timeout_ms: None,
    body_deadline: true,
    read_idle_ms: None,
    max_body_bytes: 64 * 1024 * 1024,
    follow_redirects: true,
    max_redirects: 10,
    decompress: true,
  }
}

///|
pub(open) trait Backend {
  async fn send(Self, @model.Request, RequestOptions) -> @model.Response raise @model.TransportError
  fn close(Self) -> Unit = _
}

///|
impl Backend with close(_self) {
  ()
}

///|
pub type SendFn = async (@model.Request, RequestOptions) -> @model.Response raise @model.TransportError

///|
priv struct FnBackend {
  f : SendFn
  on_close : (() -> Unit)?
}

///|
impl Backend for FnBackend with send(self, req, opts) {
  (self.f)(req, opts)
}

///|
impl Backend for FnBackend with close(self) {
  if self.on_close is Some(f) {
    f()
  }
}

///|
/// The one way to write an ad-hoc wrapper (no separate `layer`).
pub fn from_fn(f : SendFn, on_close? : () -> Unit) -> &Backend {
  FnBackend::{ f, on_close }
}

///|
pub(all) suberror ResponseError {
  UnexpectedStatus(@model.ResponseHead, body~ : Bytes)
  Deserialization(@model.ResponseHead, message~ : String, body~ : Bytes)
} derive(Debug)

///|
/// Raised by request encoders (generated SDK code) before anything is sent;
/// replaces SdkError::Config at call time.
pub(all) suberror InvalidRequest {
  InvalidRequest(message~ : String)
} derive(Debug)

///|
pub fn status_of(e : Error) -> Int? {
  match e {
    UnexpectedStatus(h, ..) | Deserialization(h, ..) => Some(h.status)
    _ => None
  }
}

///|
pub let max_error_body : Int = 1024 * 1024

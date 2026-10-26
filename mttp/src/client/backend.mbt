///|
/// Per-attempt transport settings. Build from default() and record updates.
pub(all) struct RequestOptions {
  timeout_ms : Int32?
  body_deadline : Bool
  read_idle_ms : Int32?
  max_body_bytes : Int32
  follow_redirects : Bool
  max_redirects : Int32
  decompress : Bool
} derive(Eq, Debug)

///|
/// Compares transport options.
pub extend RequestOptions with Eq::{equal, not_equal}

///|
/// Formats transport options for diagnostics.
pub extend RequestOptions with @debug.Debug::{to_repr}

///|
/// No deadline, 64 MiB buffered bodies, decoding enabled and ten redirects.
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
/// A transport returning a response head and an owned body. HTTP status codes
/// are responses, not transport errors. The caller closes each response.
pub(open) trait Backend {
  /// Sends one exchange according to the supplied options.
  async fn send(Self, @model.Request, RequestOptions) -> @model.Response raise @model.TransportError
  /// Closes the backend and its resources; implementations make this idempotent.
  fn close(Self) -> Unit = _
}

///|
impl Backend with fn close(_) {
  ()
}

///|
/// An ad-hoc backend operation with the same error contract as Backend.
pub type SendFn = async (@model.Request, RequestOptions) -> @model.Response raise @model.TransportError

///|
priv struct FnBackend {
  send : SendFn
  on_close : (() -> Unit)?
  mut closed : Bool
}

///|
impl Backend for FnBackend with fn send(self, request, options) {
  if self.closed {
    raise @model.TransportError(
      kind=Closed,
      phase=Pool,
      detail="backend is closed",
    )
  }
  request.validate()
  (self.send)(request, options)
}

///|
impl Backend for FnBackend with fn close(self) {
  if !self.closed {
    self.closed = true
    if self.on_close is Some(close) {
      close()
    }
  }
}

///|
/// Wraps a function, validating requests and invoking on_close at most once.
pub fn from_fn(send : SendFn, on_close? : () -> Unit) -> &Backend {
  FnBackend::{ send, on_close, closed: false, }
}

///|
/// Runs an in-process handler through the backend contract. Deadline options
/// are supplied to the client fallback timer; this adapter does no waiting.
pub fn from_handler(handler : @model.Handler) -> &Backend {
  from_fn((request, _) => handler(request))
}

///|
/// A received response could not be interpreted as the requested value.
/// Transport failures remain raised TransportErrors.
pub(all) enum ResponseFailure {
  UnexpectedStatus(@model.ResponseHead, body~ : Bytes)
  Deserialization(@model.ResponseHead, message~ : String, body~ : Bytes)
} derive(Eq, Debug)

///|
/// Formats response failures for diagnostics.
pub extend ResponseFailure with @debug.Debug::{to_repr}

///|
/// Compares response interpretation failures.
pub extend ResponseFailure with Eq::{equal, not_equal}

///|
/// Returns the received response metadata.
pub fn ResponseFailure::head(self : ResponseFailure) -> @model.ResponseHead {
  match self {
    UnexpectedStatus(head, ..) | Deserialization(head, ..) => head
  }
}

///|
/// A request encoder rejected input before anything was sent.
pub(all) suberror InvalidRequest {
  InvalidRequest(message~ : String)
} derive(Debug)

///|
/// Formats request encoding failures for diagnostics.
pub extend InvalidRequest with @debug.Debug::{to_repr}

///|
/// Returns Some of the received HTTP status for a response failure.
pub fn status_of(error : ResponseFailure) -> Int32? {
  Some(error.head().status)
}

///|
/// Maximum retained bytes for an unexpected response status: one MiB.
pub let max_error_body : Int32 = 1024 * 1024

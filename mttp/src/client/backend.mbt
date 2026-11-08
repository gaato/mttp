///|
priv struct FnBackend {
  send : async (@http.Request, @http.SendOptions) -> @http.Response raise @http.TransportError
  on_close : (() -> Unit)?
  mut closed : Bool
}

///|
impl @http.Backend for FnBackend with fn send(self, request, options) {
  if self.closed {
    raise @http.TransportError(
      kind=Closed,
      phase=Pool,
      detail="backend is closed",
    )
  }
  request.validate()
  options.validate()
  (self.send)(request, options)
}

///|
impl @http.Backend for FnBackend with fn close(self) {
  if !self.closed {
    self.closed = true
    if self.on_close is Some(close) {
      close()
    }
  }
}

///|
/// Wraps a function as a backend. The wrapper refuses an invalid request or
/// invalid options before calling `send` (`Request::validate`, a stream
/// body declaring a negative length, `SendOptions::validate`; all unsent),
/// refuses sends after `close` (`TransportError(Closed, Pool)`), and calls
/// `on_close` at most once.
/// `send` receives the options unchanged and owns the rest of the Backend
/// contract: it closes a request stream it takes and leaves the response
/// body to the caller.
pub fn from_fn(
  send : async (@http.Request, @http.SendOptions) -> @http.Response raise @http.TransportError,
  on_close? : () -> Unit,
) -> &@http.Backend {
  FnBackend::{ send, on_close, closed: false, }
}

///|
/// Runs an in-process handler as a backend, through `from_fn`. The handler
/// does no waiting on `SendOptions`; a `Client` with a Timer still bounds
/// each attempt with its own deadline.
pub fn from_handler(handler : @http.Handler) -> &@http.Backend {
  from_fn((request, _) => handler(request))
}

///|
/// A received response that is not the value the description asked for. It
/// is a value: readers return it as `Err`, and transport failures stay
/// raised `TransportError`s.
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum ResponseFailure {
  /// The status was rejected. `body` keeps at most `max_error_body` bytes of
  /// the response body, for diagnostics.
  UnexpectedStatus(@http.ResponseHead, body~ : Bytes)
  /// The body could not be decoded. `body` keeps at most `max_error_body`
  /// bytes of it.
  Deserialization(@http.ResponseHead, message~ : String, body~ : Bytes)
}

///|
/// Formats response failures for diagnostics.
pub extend ResponseFailure with @debug.Debug::{to_repr}

///|
/// Compares response interpretation failures.
pub extend ResponseFailure with Eq::{equal, not_equal}

///|
/// Returns the received response metadata.
pub fn ResponseFailure::head(self : ResponseFailure) -> @http.ResponseHead {
  match self {
    UnexpectedStatus(head, ..) | Deserialization(head, ..) => head
  }
}

///|
/// A request encoder rejected input before anything was sent.
#derive(Debug)
pub(all) suberror InvalidRequest {
  InvalidRequest(message~ : String)
}

///|
/// Formats request encoding failures for diagnostics.
pub extend InvalidRequest with @debug.Debug::{to_repr}

///|
/// Returns Some of the received HTTP status for a response failure.
pub fn status_of(error : ResponseFailure) -> Int32? {
  Some(error.head().status)
}

///|
/// Maximum retained bytes of a rejected or undecodable body: one MiB.
pub let max_error_body : Int32 = 1024 * 1024

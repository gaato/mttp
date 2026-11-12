// The transport seam. A Backend moves one exchange and nothing more: the
// connection engines of gaato/mttp_core, gaato/mttp's runtime backends, and the
// wrappers and stubs of gaato/mttp_core all implement it, so a client policy is
// written once against this trait. CONTRACT.md (Backend; SendOptions and
// BodyTiming) states what each side may rely on.

///|
/// A transport for one exchange: it sends the request and returns the
/// response head with a body the caller owns, reads to EOF or closes. HTTP
/// statuses are responses, not errors; a failure to get one is a
/// `TransportError` carrying the phase it happened in.
///
/// A backend refuses an invalid request before any I/O
/// (`Request::validate`, `SendOptions::validate`), moves raw bytes (no
/// redirects, retries, cookies or content decoding), and propagates
/// cancellation unchanged. After `close`, new sends fail with
/// `TransportError(Closed, Pool)`.
pub(open) trait Backend {
  /// Sends one exchange under `options`.
  async fn send(Self, Request, SendOptions) -> Response raise TransportError
  /// Releases the backend's resources. Idempotent; the default does nothing.
  fn close(Self) -> Unit = _
}

///|
impl Backend with fn close(_) {
  ()
}

///|
/// How the caller will consume the response body, which decides what the
/// attempt deadline covers and how many bytes the backend admits.
///
/// ```mbt check
/// test {
///   let options = { ..@mttp_core.SendOptions::default(), timeout_ms: Some(5000), }
///   assert_eq(options.body, Exchange(max_bytes=64 * 1024 * 1024))
///   let streaming = { ..options, body: Stream(idle_ms=Some(30000)), }
///   assert_eq(streaming.timeout_ms, Some(5000))
/// }
/// ```
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum BodyTiming {
  /// The caller reads the whole body inside the attempt: `timeout_ms` covers
  /// the head and the body, and at most `max_bytes` body bytes are admitted
  /// from the wire (after transfer framing, before content decoding). The
  /// read that would cross the limit raises `TooLarge(limit)` in phase Body.
  Exchange(max_bytes~ : Int32)
  /// The caller streams the body: `timeout_ms` ends when the head arrives,
  /// and each later read waits at most `idle_ms` (`None`: no idle limit).
  /// The total length is the reader's to bound.
  Stream(idle_ms~ : Int32?)
}

///|
/// Compares body timings.
pub extend BodyTiming with Eq::{equal, not_equal}

///|
/// Formats a body timing for diagnostics.
pub extend BodyTiming with @debug.Debug::{to_repr}

///|
/// The per-send settings a caller hands a `Backend`. Build them from
/// `SendOptions::default()` with a record update; the field set is frozen.
#derive(Eq, Debug)
pub(all) struct SendOptions {
  /// The attempt deadline in milliseconds, or `None` for none at this layer.
  timeout_ms : Int32?
  /// What the deadline covers and how many body bytes are admitted.
  body : BodyTiming
}

///|
/// Compares send options.
pub extend SendOptions with Eq::{equal, not_equal}

///|
/// Formats send options for diagnostics.
pub extend SendOptions with @debug.Debug::{to_repr}

///|
/// No attempt deadline and a buffered body of at most 64 MiB on the wire.
pub fn SendOptions::default() -> SendOptions {
  { timeout_ms: None, body: Exchange(max_bytes=64 * 1024 * 1024), }
}

///|
/// Refuses options no send can honour, before any I/O and so unsent: a
/// nonpositive `timeout_ms` raises `Timeout(ms)` at once, and a negative
/// `Exchange(max_bytes)` or a nonpositive `Stream(idle_ms)` raises
/// `Invalid`, all in phase Pool. `Exchange(max_bytes=0)` is valid and admits
/// only an empty body; an idle limit of zero is refused because no read
/// could ever meet it.
///
/// ```mbt check
/// test {
///   @mttp_core.SendOptions::default().validate()
///   let bad = {
///     ..@mttp_core.SendOptions::default(),
///     body: Exchange(max_bytes=-1),
///   }
///   try bad.validate() catch {
///     @mttp_core.TransportError(kind~, phase~, ..) => {
///       assert_eq(kind, Invalid)
///       assert_eq(phase, Pool)
///     }
///   } noraise {
///     _ => fail("a negative byte limit must be refused")
///   }
/// }
/// ```
pub fn SendOptions::validate(self : SendOptions) -> Unit raise TransportError {
  if self.timeout_ms is Some(ms) && ms <= 0 {
    raise TransportError(
      kind=Timeout(ms~),
      phase=Pool,
      detail="the attempt deadline is not positive",
    )
  }
  match self.body {
    Exchange(max_bytes~) if max_bytes < 0 =>
      raise TransportError(
        kind=Invalid,
        phase=Pool,
        detail="negative body byte limit",
      )
    Stream(idle_ms=Some(ms)) if ms <= 0 =>
      raise TransportError(
        kind=Invalid,
        phase=Pool,
        detail="the idle read limit is not positive",
      )
    _ => ()
  }
}

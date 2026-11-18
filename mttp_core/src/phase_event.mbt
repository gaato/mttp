///|
/// A point one attempt's exchange reached in its backend, for observation
/// only (CONTRACT.md, Backend rule 13). A backend reports the points it can
/// see, in the order below, each at most once per attempt, and never after
/// the send returned or raised; JS fetch sees none of them and reports
/// nothing. The cases are declared in the order they happen.
///
/// ```mbt check
/// test {
///   let seen = []
///   let request = @mttp_core.Request::get("http://example.test/")
///   let request = {
///     ..request,
///     attributes: request.attributes.put(@mttp_core.on_phase, event => {
///       seen.push(event)
///     }),
///   }
///   // A backend looks the callback up and reports what it reached.
///   if request.attributes.get(@mttp_core.on_phase) is Some(report) {
///     report(Dialed(addr="example.test:80"))
///     report(Pooled(reused=false))
///   }
///   assert_eq(seen, [Dialed(addr="example.test:80"), Pooled(reused=false)])
/// }
/// ```
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum PhaseEvent {
  /// A new connection is open to `addr`, written `host:port` with an IPv6
  /// host in brackets: the origin, or the proxy when one carries the
  /// request (OpenTelemetry `server.address` and `server.port`).
  Dialed(addr~ : String)
  /// The connection's TLS handshake finished.
  TlsDone
  /// The attempt has its connection: `reused` is true for one taken from
  /// the idle pool (no `Dialed` or `TlsDone` precedes it), false for one
  /// dialled for it.
  Pooled(reused~ : Bool)
  /// The whole request, head and body, was written.
  Written
  /// The first byte of the response arrived.
  FirstByte
}

///|
/// Compares phase events.
pub extend PhaseEvent with Eq::{equal, not_equal}

///|
/// Formats a phase event for diagnostics.
pub extend PhaseEvent with @debug.Debug::{to_repr}

///|
/// Set on a request by the caller that wants its backend's `PhaseEvent`s:
/// the backend calls it as the exchange reaches each point. A `Client`
/// built with `events` sets it on every attempt, calling a callback the
/// request already carries first, so both are told. Wrappers pass request
/// attributes on, so it reaches the engine underneath.
pub let on_phase : AttributeKey[(PhaseEvent) -> Unit] = AttributeKey::new(
  "on_phase",
)

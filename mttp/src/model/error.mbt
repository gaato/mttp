///|
/// The exchange phase in which a failure occurred.
#non_exhaustive
pub(all) enum Phase {
  Pool
  Dial
  Write
  Head
  Body
  Unknown
} derive(Eq, Debug)

///|
/// Transport failure category, distinct from an HTTP status response.
#non_exhaustive
pub(all) enum Kind {
  Invalid
  Connect
  Timeout(ms~ : Int32)
  Network
  Protocol
  Proxy(status~ : Int32)
  TooLarge(limit~ : Int32)
  TooManyRedirects(max~ : Int32)
  RedirectRefused
  Unreplayable
  Closed
} derive(Eq, Debug)

///|
/// A failure with its category, phase and diagnostic description.
pub(all) suberror TransportError {
  TransportError(kind~ : Kind, phase~ : Phase, detail~ : String)
} derive(Debug)

///|
/// Whether the failure proves no request bytes reached the origin.
pub fn TransportError::is_unsent(self : TransportError) -> Bool {
  let TransportError(kind~, phase~, ..) = self
  match (kind, phase) {
    (Connect | Proxy(..), _) | (Timeout(..), Pool | Dial) | (Closed, Pool) =>
      true
    _ => false
  }
}

///|
/// A human-readable diagnostic including category and phase.
pub fn TransportError::message(self : TransportError) -> String {
  let TransportError(kind~, phase~, detail~) = self
  "\{@debug.to_string(kind)} during \{@debug.to_string(phase)}: \{detail}"
}

///|
/// A stream with nonempty chunks, sticky EOF and idempotent close.
pub(open) trait BodyStream {
  /// Returns the next nonempty chunk or permanent EOF.
  async fn read_some(Self) -> Bytes? raise TransportError
  /// Releases resources; subsequent reads return EOF.
  fn close(Self) -> Unit
}

///|
/// The exchange phase in which a failure occurred.
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum Phase {
  Pool
  Dial
  Write
  Head
  Body
  Unknown
}

///|
/// Transport failure category, distinct from an HTTP status response.
#derive(Eq, Debug)
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
}

///|
/// A failure with its category, phase and diagnostic description.
#derive(Debug)
pub(all) suberror TransportError {
  TransportError(kind~ : Kind, phase~ : Phase, detail~ : String)
}

///|
/// Whether the failure proves no request bytes reached the origin: it
/// happened in phase Pool or Dial (CONTRACT.md, Backend rule 2), or it is a
/// connect failure or a proxy's refusal, which precede the request. Whether
/// resending is worthwhile is a separate question: an `Invalid` request is
/// unsent and fails the same way again.
pub fn TransportError::is_unsent(self : TransportError) -> Bool {
  let TransportError(kind~, phase~, ..) = self
  kind is (Connect | Proxy(..)) || phase is (Pool | Dial)
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

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
  /// The transport ended without its own end-of-stream signal: a TLS
  /// session's peer closed the connection beneath without sending
  /// close_notify. RFC 9112, section 9.8 calls this an incomplete close.
  /// Where the message framing delimits the message, it counts as EOF;
  /// only a body delimited by the close itself is then truncated.
  IncompleteClose
  /// The peer said it did not process the request, so it may be sent again
  /// whatever its method: an HTTP/2 stream reset with REFUSED_STREAM or
  /// above a GOAWAY's last stream identifier (RFC 9113, section 8.7), or
  /// HTTP/3's H3_REQUEST_REJECTED (RFC 9114, section 8.1). The phase stays
  /// the one the exchange reached, since request bytes may have been
  /// written before the refusal.
  Refused
  /// A circuit breaker (`@client.CircuitBreaker`) refused the request
  /// without sending it, because recent requests to its origin failed. It
  /// comes in phase Pool, so it is unsent, and the retry rules never retry
  /// it: retrying at once would meet the same open circuit.
  CircuitOpen
}

///|
/// A failure with its category, phase and diagnostic description.
#derive(Debug)
pub(all) suberror TransportError {
  TransportError(kind~ : Kind, phase~ : Phase, detail~ : String)
}

///|
/// Whether the failure proves the origin did not act on the request: no
/// request bytes reached it, because the failure happened in phase Pool or
/// Dial (CONTRACT.md, Backend rule 2) or is a connect failure or a proxy's
/// refusal, which precede the request; or the origin said it did not
/// process the request (`Refused`). Whether resending is worthwhile is a
/// separate question: an `Invalid` request is unsent and fails the same way
/// again.
pub fn TransportError::is_unsent(self : TransportError) -> Bool {
  let TransportError(kind~, phase~, ..) = self
  kind is (Connect | Proxy(..) | Refused) || phase is (Pool | Dial)
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

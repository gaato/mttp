///|
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
#non_exhaustive
pub(all) enum Kind {
  Invalid
  Connect
  Timeout(ms~ : Int)
  Network
  Protocol
  Proxy(status~ : Int)
  TooLarge(limit~ : Int)
  TooManyRedirects(max~ : Int)
  RedirectRefused
  Unreplayable
  Closed
} derive(Eq, Debug)

///|
pub(all) suberror TransportError {
  TransportError(kind~ : Kind, phase~ : Phase, detail~ : String)
} derive(Debug)

///|
pub fn TransportError::is_unsent(self : TransportError) -> Bool {
  let TransportError(kind~, phase~, ..) = self
  match (kind, phase) {
    (Connect, _) | (_, Pool) | (_, Dial) => true
    _ => false
  }
}

///|
pub fn TransportError::message(self : TransportError) -> String {
  let TransportError(kind~, phase~, detail~) = self
  "\{debug_string(kind)} during \{debug_string(phase)}: \{detail}"
}

///|
fn[T : @debug.Debug] debug_string(v : T) -> String {
  @debug.to_string(v)
}

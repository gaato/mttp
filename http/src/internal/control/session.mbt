// What the h1server engine knows about one connection's peer while it reads
// the next request: whether an exchange is running, whether the peer ended
// its stream, and whether reading from it failed. A clean EOF lets a
// running exchange finish its response; a read failure cancels it.

///|
/// One connection's peer state.
pub(all) struct SessionState {
  /// An exchange is running.
  busy : Bool
  /// The peer ended its stream (EOF on the read half).
  peer_eof : Bool
  /// Reading from the peer failed.
  failed : Bool
}

///|
/// An event observed on one connection.
pub(all) enum SessionEvent {
  /// An exchange starts.
  Begin
  /// The running exchange finished.
  Finish
  /// The peer's stream ended cleanly.
  PeerEof
  /// Reading from the peer failed.
  PeerFailure
}

///|
/// The state after an event, and whether the running exchange is to be
/// cancelled.
pub(all) struct SessionChange {
  state : SessionState
  cancel_exchange : Bool
}

///|
/// An idle connection whose peer is still there.
pub fn SessionState::new() -> SessionState {
  { busy: false, peer_eof: false, failed: false, }
}

///|
/// Applies `event`. Only a read failure during an exchange cancels it; EOF
/// keeps a running exchange so its response can still be written.
pub fn SessionState::step(
  self : SessionState,
  event : SessionEvent,
) -> SessionChange {
  match event {
    Begin => { state: { ..self, busy: true, }, cancel_exchange: false, }
    Finish => { state: { ..self, busy: false, }, cancel_exchange: false, }
    PeerEof => { state: { ..self, peer_eof: true, }, cancel_exchange: false, }
    PeerFailure =>
      { state: { ..self, failed: true, }, cancel_exchange: self.busy, }
  }
}

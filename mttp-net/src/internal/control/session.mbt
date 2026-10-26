///|
pub(all) struct SessionState {
  busy : Bool
  peer_eof : Bool
  failed : Bool
}

///|
pub(all) enum SessionEvent {
  Begin
  Finish
  PeerEof
  PeerFailure
}

///|
pub(all) struct SessionChange {
  state : SessionState
  cancel_exchange : Bool
}

///|
pub fn SessionState::new() -> SessionState {
  { busy: false, peer_eof: false, failed: false, }
}

///|
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

///|
/// Compares message kinds.
pub extend WsData with Eq::{equal, not_equal}

///|
/// Formats message kinds for diagnostics.
pub extend WsData with @debug.Debug::{to_repr}

///|
/// Compares assembly snapshots.
pub extend WsAssembly with Eq::{equal, not_equal}

///|
/// Formats assembly snapshots for diagnostics.
pub extend WsAssembly with @debug.Debug::{to_repr}

///|
/// Compares close phases.
pub extend WsClosing with Eq::{equal, not_equal}

///|
/// Formats close phases for diagnostics.
pub extend WsClosing with @debug.Debug::{to_repr}

///|
/// Compares close handshake snapshots.
pub extend WsCloseState with Eq::{equal, not_equal}

///|
/// Formats close handshake snapshots for diagnostics.
pub extend WsCloseState with @debug.Debug::{to_repr}

///|
/// Compares keepalive snapshots.
pub extend WsLife with Eq::{equal, not_equal}

///|
/// Formats keepalive snapshots for diagnostics.
pub extend WsLife with @debug.Debug::{to_repr}

///|
/// Message kind retained between continuation frames.
#derive(Eq, Debug)
pub(all) enum WsData {
  Text
  Binary
}

///|
/// Fragment assembly; control frames leave this snapshot unchanged.
#derive(Eq, Debug)
pub(all) enum WsAssembly {
  Idle
  InMessage(WsData)
}

///|
/// None refuses a new data frame or an orphan continuation.
pub fn WsAssembly::data(
  self : WsAssembly,
  kind : WsData?,
  fin~ : Bool,
) -> (WsAssembly, WsData)? {
  match (self, kind) {
    (Idle, Some(k)) | (InMessage(k), None) =>
      Some((if fin { Idle } else { InMessage(k) }, k))
    _ => None
  }
}

///|
/// Closing records who started; sent is committed before writing Close.
#derive(Eq, Debug)
pub(all) enum WsClosing {
  Open
  Closing(locally~ : Bool)
  Closed
}

///|
/// Close phase plus committed send and receive facts; no I/O resources.
#derive(Eq, Debug)
pub(all) struct WsCloseState {
  phase : WsClosing
  sent : Bool
  received : Bool
}

///|
/// An open handshake with no Close sent or received.
pub fn WsCloseState::new() -> WsCloseState {
  { phase: Open, sent: false, received: false, }
}

///|
/// Begins a local Close once; later requests leave the original phase intact.
pub fn WsCloseState::request(self : WsCloseState) -> WsCloseState {
  match self.phase {
    Open => { ..self, phase: Closing(locally=true), }
    _ => self
  }
}

///|
/// The bool authorizes exactly one Close write.
pub fn WsCloseState::send(self : WsCloseState) -> (WsCloseState, Bool) {
  if self.phase is Closed || self.sent {
    return (self, false)
  }
  ({ ..self.request(), sent: true, }, true)
}

///|
/// Records the peer's Close without replacing the original initiator.
pub fn WsCloseState::receive(self : WsCloseState) -> WsCloseState {
  if self.phase is Closed {
    return self
  }
  let phase = match self.phase {
    Open => Closing(locally=false)
    _ => self.phase
  }
  { ..self, phase, received: true, }
}

///|
/// Ends the handshake permanently; Closed is absorbing under every operation.
pub fn WsCloseState::finish(self : WsCloseState) -> WsCloseState {
  { ..self, phase: Closed, }
}

///|
/// Only Open admits data or new Ping/Pong writes.
pub fn WsCloseState::data_allowed(self : WsCloseState) -> Bool {
  self.phase is Open
}

///|
/// Any received byte ends the answer wait, irrespective of its opcode.
#derive(Eq, Debug)
pub(all) enum WsLife {
  Alive(Int64)
  Waiting(Int64)
  Zombie
}

///|
/// Any incoming byte renews life; a zombie cannot be revived.
pub fn WsLife::received(self : WsLife, now : Int64) -> WsLife {
  match self {
    Zombie => Zombie
    _ => Alive(now)
  }
}

///|
/// Starts the answer deadline when the Ping is fully on wire. A byte received
/// during that write already established life, so it keeps its own timestamp.
pub fn WsLife::sent(self : WsLife, now : Int64) -> WsLife {
  match self {
    Waiting(_) => Waiting(now)
    _ => self
  }
}

///|
/// Returns a Ping action once per interval; a nonpositive option is disabled.
pub fn WsLife::tick(
  self : WsLife,
  now : Int64,
  interval : Int32?,
  answer : Int32?,
) -> (WsLife, Bool) {
  match (self, interval, answer) {
    (Alive(last), Some(i), Some(a)) if i > 0 &&
      a > 0 &&
      now - last >= i.to_int64() => (Waiting(now), true)
    (Waiting(start), _, Some(a)) if a > 0 && now - start >= a.to_int64() =>
      (Zombie, false)
    _ => (self, false)
  }
}

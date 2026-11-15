///|
priv struct WsPipe {
  messages : Array[@ws.Message]
  mut ended : @ws.CloseFrame?
  mut changed : &@rt.Signal
}

///|
/// Message-level session for in-process upgrades. The paired peer is always
/// present, so close commits the handshake synchronously before returning.
pub struct WebSocketStub {
  priv input : WsPipe
  priv output : WsPipe
  priv coordination : &@rt.Coordination
  priv protocol : String?
  priv mut reading : Bool
}

///|
/// Both ends implement Session; no byte codec or HTTP handshake is involved.
pub fn WebSocketStub::pair(
  coordination : &@rt.Coordination,
  subprotocol? : String,
) -> (&@ws.Session, &@ws.Session) {
  let left = WsPipe::{
    messages: [],
    ended: None,
    changed: coordination.signal(),
  }
  let right = WsPipe::{
    messages: [],
    ended: None,
    changed: coordination.signal(),
  }
  (
    WebSocketStub::{
      input: left,
      output: right,
      coordination,
      protocol: subprotocol,
      reading: false,
    },
    WebSocketStub::{
      input: right,
      output: left,
      coordination,
      protocol: subprotocol,
      reading: false,
    },
  )
}

///|
fn WebSocketStub::wake(self : WebSocketStub, pipe : WsPipe) -> Unit {
  let old = pipe.changed
  pipe.changed = self.coordination.signal()
  old.notify()
}

///|
/// Waits for a message or the paired peer's close, retaining queued messages
/// when the waiting receiver is cancelled.
pub impl @ws.Session for WebSocketStub with fn recv(self) {
  if self.reading {
    raise @ws.WsError(kind=Protocol, detail="concurrent stub recv")
  }
  self.reading = true
  defer {
    self.reading = false
  }
  for ;; {
    if self.input.ended is Some(frame) {
      raise @ws.WsError(kind=Closed(frame), detail="stub closed")
    }
    if !self.input.messages.is_empty() {
      return self.input.messages.remove(0)
    }
    self.input.changed.wait()
  }
}

///|
/// Queues a complete message in call order; there is no partial byte write.
pub impl @ws.Session for WebSocketStub with fn send(self, message) {
  if self.output.ended is Some(frame) {
    raise @ws.WsError(kind=Closed(frame), detail="stub closed")
  }
  self.output.messages.push(message)
  self.wake(self.output)
}

///|
fn WebSocketStub::finish(self : WebSocketStub, frame : @ws.CloseFrame) -> Unit {
  if self.input.ended is None {
    self.input.ended = Some(frame)
  }
  if self.output.ended is None {
    self.output.ended = Some(frame)
  }
  self.input.messages.clear()
  self.output.messages.clear()
  self.wake(self.input)
  self.wake(self.output)
}

///|
/// Commits Close at both ends; the in-process peer always acknowledges at once.
pub impl @ws.Session for WebSocketStub with fn close(self, frame) {
  let _ = frame.encode() catch {
    _ => {
      self.finish({ code: Abnormal, reason: "", })
      return
    }
  }
  self.finish(frame)
}

///|
/// Ends both ends with local abnormal status, preserving an earlier Close.
pub impl @ws.Session for WebSocketStub with fn abort(self) {
  self.finish({ code: Abnormal, reason: "", })
}

///|
/// The protocol supplied when the pair was created.
pub impl @ws.Session for WebSocketStub with fn subprotocol(self) {
  self.protocol
}

///|
/// Makes the Session operations available on a concrete stub.
pub extend WebSocketStub with @ws.Session::{
  recv,
  send,
  close,
  abort,
  subprotocol,
}

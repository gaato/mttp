///|
/// Deterministic read events. Wait provides a cancellation or deadline point;
/// a notification resumes the same read at the next scripted event.
pub(all) enum ReadStep {
  Chunk(Bytes)
  Eof
  Failure(@model.TransportError)
  Wait(&@connection.Signal)
}

///|
/// A fault-injection connection with bounded reads and recorded whole writes.
/// Script exhaustion is permanent EOF. Errors remain sticky until close.
pub struct ScriptedConn {
  priv steps : Array[ReadStep]
  priv mut pending : Bytes
  priv mut ended : Bool
  priv mut closed : Bool
  priv mut failure : @model.TransportError?
  priv write_failure : @model.TransportError?
  priv mut blocked : &@connection.Signal?
  priv writes : Array[Bytes]
  priv mut close_count : Int32
}

///|
/// Copies read events and optionally fails every write with write_error.
pub fn ScriptedConn::new(
  steps : Array[ReadStep],
  write_error? : @model.TransportError,
) -> ScriptedConn {
  {
    steps: steps.copy(),
    pending: b"",
    ended: false,
    closed: false,
    failure: None,
    write_failure: write_error,
    blocked: None,
    writes: [],
    close_count: 0,
  }
}

///|
/// Returns a snapshot of successful whole writes.
pub fn ScriptedConn::written(self : ScriptedConn) -> Array[Bytes] {
  self.writes.copy()
}

///|
/// Counts the first close only, for exactly-once cleanup assertions.
pub fn ScriptedConn::closes(self : ScriptedConn) -> Int32 {
  self.close_count
}

///|
/// Makes portable connection operations available as methods.
pub extend ScriptedConn with @connection.Conn::{read, write, close}

///|
/// Interprets bounded chunks, permanent EOF, sticky faults and cancellable waits.
pub impl @connection.Conn for ScriptedConn with fn read(self, max_len~) {
  if max_len <= 0 {
    raise @model.TransportError(
      kind=Invalid,
      phase=Body,
      detail="nonpositive read size",
    )
  }
  for ;; {
    if self.closed || self.ended {
      return None
    }
    if self.failure is Some(error) {
      raise error
    }
    if !self.pending.is_empty() {
      let take = self.pending.length().min(max_len)
      let bytes = self.pending[:take].to_owned()
      self.pending = self.pending[take:].to_owned()
      return Some(bytes)
    }
    if self.steps.is_empty() {
      self.ended = true
      return None
    }
    match self.steps.remove(0) {
      Chunk(bytes) => self.pending = bytes
      Eof => self.ended = true
      Failure(error) => self.failure = Some(error)
      Wait(signal) => {
        self.blocked = Some(signal)
        defer {
          self.blocked = None
        }
        signal.wait()
      }
    }
  }
}

///|
/// Records successful writes and preserves injected write failures.
pub impl @connection.Conn for ScriptedConn with fn write(self, bytes) {
  if self.closed {
    raise @model.TransportError(
      kind=Network,
      phase=Write,
      detail="connection closed",
    )
  }
  if self.write_failure is Some(error) {
    raise error
  }
  self.writes.push(bytes)
}

///|
/// Closes once, discards unread events and wakes a pending scripted wait.
pub impl @connection.Conn for ScriptedConn with fn close(self) {
  if !self.closed {
    self.closed = true
    self.close_count += 1
    self.pending = b""
    self.steps.clear()
    if self.blocked is Some(signal) {
      signal.notify()
    }
  }
}

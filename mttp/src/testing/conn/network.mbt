///|
priv struct Pipe {
  queue : Array[Bytes]
  mut pending : Bytes
  mut ended : Bool
  mut reader_closed : Bool
  mut changed : &@connection.Signal
}

///|
/// One endpoint of an in-memory full-duplex connection. shutdown_write models
/// FIN separately from close, allowing half-close and response tests.
pub struct SimConn {
  priv input : Pipe
  priv output : Pipe
  priv coordination : &@connection.Coordination
  priv chunk_bytes : Int32
  priv mut closed : Bool
  priv mut close_count : Int32
}

///|
/// Creates paired endpoints; chunk_bytes controls fragmentation in both directions.
pub fn pair(
  coordination : &@connection.Coordination,
  chunk_bytes~ : Int32 = 65536,
) -> (SimConn, SimConn) {
  let left = Pipe::{
    queue: [],
    pending: b"",
    ended: false,
    reader_closed: false,
    changed: coordination.signal(),
  }
  let right = Pipe::{
    queue: [],
    pending: b"",
    ended: false,
    reader_closed: false,
    changed: coordination.signal(),
  }
  (
    {
      input: left,
      output: right,
      coordination,
      chunk_bytes: chunk_bytes.max(1),
      closed: false,
      close_count: 0,
    },
    {
      input: right,
      output: left,
      coordination,
      chunk_bytes: chunk_bytes.max(1),
      closed: false,
      close_count: 0,
    },
  )
}

///|
/// Ends only the outgoing byte stream; the incoming half remains readable.
pub fn SimConn::shutdown_write(self : SimConn) -> Unit {
  self.output.ended = true
  self.output.changed.notify()
}

///|
/// Counts the first close only, for exactly-once cleanup assertions.
pub fn SimConn::closes(self : SimConn) -> Int32 {
  self.close_count
}

///|
/// Reads queued bytes with both configured fragmentation and caller bounds.
pub impl @connection.Conn for SimConn with fn read(self, max_len~) {
  if max_len <= 0 {
    raise @model.TransportError(
      kind=Invalid,
      phase=Body,
      detail="nonpositive read size",
    )
  }
  for ;; {
    if self.closed {
      return None
    }
    if self.input.pending.is_empty() && !self.input.queue.is_empty() {
      self.input.pending = self.input.queue.remove(0)
    }
    if !self.input.pending.is_empty() {
      let n = self.input.pending.length().min(max_len).min(self.chunk_bytes)
      let bytes = self.input.pending[:n].to_owned()
      self.input.pending = self.input.pending[n:].to_owned()
      return Some(bytes)
    }
    if self.input.ended {
      return None
    }
    let changed = self.input.changed
    changed.wait()
    self.input.changed = self.coordination.signal()
  }
}

///|
/// Queues all bytes or refuses a closed writing or peer-reading half.
pub impl @connection.Conn for SimConn with fn write(self, bytes) {
  if self.closed || self.output.ended || self.output.reader_closed {
    raise @model.TransportError(
      kind=Network,
      phase=Write,
      detail="closed simulated connection",
    )
  }
  if !bytes.is_empty() {
    self.output.queue.push(bytes)
    self.output.changed.notify()
  }
}

///|
/// Closes both halves once and wakes a blocked reader.
pub impl @connection.Conn for SimConn with fn close(self) {
  if !self.closed {
    self.closed = true
    self.close_count += 1
    self.input.reader_closed = true
    self.input.pending = b""
    self.input.queue.clear()
    self.input.changed.notify()
    self.shutdown_write()
  }
}

///|
/// Makes portable connection operations available as methods.
pub extend SimConn with @connection.Conn::{read, write, close}

///|
/// A deterministic dialer. TLS upgrades are recorded protocol events; real
/// certificate validation remains covered by the runtime adapter tests.
pub struct ScriptedDialer {
  priv connections : Array[&@connection.Conn]
  priv addresses : Array[(String, Int32)]
  priv upgrades : Array[String]
}

///|
/// Consumes a copy of this connection queue in dial order.
pub fn ScriptedDialer::new(
  connections : Array[&@connection.Conn],
) -> ScriptedDialer {
  { connections: connections.copy(), addresses: [], upgrades: [], }
}

///|
/// Returns a snapshot of requested host/port pairs.
pub fn ScriptedDialer::dialed(self : ScriptedDialer) -> Array[(String, Int32)] {
  self.addresses.copy()
}

///|
/// Returns a snapshot of requested TLS hostnames, including nested upgrades.
pub fn ScriptedDialer::tls_hosts(self : ScriptedDialer) -> Array[String] {
  self.upgrades.copy()
}

///|
/// Records the dial and consumes the next connection, failing if the script is exhausted.
pub impl @connection.Dialer for ScriptedDialer with fn connect(
  self,
  host~,
  port~,
) {
  self.addresses.push((host, port))
  if self.connections.is_empty() {
    raise @model.TransportError(
      kind=Connect,
      phase=Dial,
      detail="no scripted connection",
    )
  }
  self.connections.remove(0)
}

///|
/// Records an upgrade and returns the same connection without cryptography.
pub impl @connection.Dialer for ScriptedDialer with fn start_tls(
  self,
  conn,
  host~,
) {
  self.upgrades.push(host)
  conn
}

///|
/// Makes portable dialer operations available as methods.
pub extend ScriptedDialer with @connection.Dialer::{connect, start_tls}

///|
/// One scripted event of a ScriptedConn's reads.
#non_exhaustive
pub(all) enum ReadStep {
  /// Bytes to return, sliced to each read's `max_len`; empty ones are
  /// skipped.
  Chunk(Bytes)
  /// Permanent EOF.
  Eof
  /// A failure raised by this and every later read, until close.
  Failure(@http.TransportError)
  /// Blocks the read until the signal is notified or the connection closes;
  /// a point where a test can cancel the reader or let a deadline expire.
  Wait(&@rt.Signal)
}

///|
/// A connection that plays a script of read events and records whole
/// writes, for injecting faults. A script that runs out is EOF.
pub struct ScriptedConn {
  priv steps : Array[ReadStep]
  priv mut pending : Bytes
  priv mut ended : Bool
  priv mut closed : Bool
  priv mut failure : @http.TransportError?
  priv write_failure : @http.TransportError?
  priv mut blocked : &@rt.Signal?
  priv writes : Array[Bytes]
  priv mut close_count : Int32
}

///|
/// Creates a connection that plays a copy of `steps`. With `write_error`,
/// every write raises it.
///
/// ```mbt check
/// test {
///   let conn = @sim.ScriptedConn::new([Chunk(b"HTTP/1.1"), Eof])
///   @driver.run_sync(() => {
///     assert_eq(conn.read(max_len=4), Some(b"HTTP"))
///     assert_eq(conn.read(max_len=4), Some(b"/1.1"))
///     assert_eq(conn.read(max_len=4), None)
///     conn.write(b"GET / HTTP/1.1\r\n\r\n")
///   })
///   assert_eq(conn.written(), [b"GET / HTTP/1.1\r\n\r\n"])
/// }
/// ```
pub fn ScriptedConn::new(
  steps : Array[ReadStep],
  write_error? : @http.TransportError,
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
/// A copy of the successful writes, one entry per `write`.
pub fn ScriptedConn::written(self : ScriptedConn) -> Array[Bytes] {
  self.writes.copy()
}

///|
/// How many times the connection was closed: 0 or 1, however often `close`
/// is called.
pub fn ScriptedConn::closes(self : ScriptedConn) -> Int32 {
  self.close_count
}

///|
/// Plays the script: bounded chunks, permanent EOF, sticky failures and
/// cancellable waits. A nonpositive `max_len` raises `Invalid`.
pub impl @rt.Conn for ScriptedConn with fn read(self, max_len~) {
  if max_len <= 0 {
    raise @http.TransportError(
      kind=Invalid,
      phase=Unknown,
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
/// Records the write, or raises the configured write error; raises
/// `Network` after close.
pub impl @rt.Conn for ScriptedConn with fn write(self, bytes) {
  if self.closed {
    raise @http.TransportError(
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
/// Closes once, drops the rest of the script and wakes a pending wait.
pub impl @rt.Conn for ScriptedConn with fn close(self) {
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

///|
/// The connection operations as methods of the double.
pub extend ScriptedConn with @rt.Conn::{read, write, close}

///|
/// A dialer that hands out prepared connections in order and records what
/// was asked of it. A TLS upgrade is recorded and returns the same
/// connection: no cryptography happens, and certificate checks belong to the
/// runtime adapter's own tests.
pub struct ScriptedDialer {
  priv connections : Array[&@rt.Conn]
  priv addresses : Array[(String, Int32)]
  priv upgrades : Array[String]
}

///|
/// Creates a dialer that hands out a copy of `connections`, first to last.
pub fn ScriptedDialer::new(connections : Array[&@rt.Conn]) -> ScriptedDialer {
  { connections: connections.copy(), addresses: [], upgrades: [], }
}

///|
/// A copy of the dialled host and port pairs, in order.
pub fn ScriptedDialer::dialed(self : ScriptedDialer) -> Array[(String, Int32)] {
  self.addresses.copy()
}

///|
/// A copy of the hosts of the TLS upgrades, in order; a TLS session inside
/// a tunnel to a TLS proxy shows as two entries.
pub fn ScriptedDialer::tls_hosts(self : ScriptedDialer) -> Array[String] {
  self.upgrades.copy()
}

///|
/// Records the address and hands out the next connection; raises
/// `Connect` in phase Dial when none is left.
pub impl @rt.Dialer for ScriptedDialer with fn connect(self, host~, port~) {
  self.addresses.push((host, port))
  if self.connections.is_empty() {
    raise @http.TransportError(
      kind=Connect,
      phase=Dial,
      detail="no scripted connection",
    )
  }
  self.connections.remove(0)
}

///|
/// Records the upgrade and returns `conn` itself.
pub impl @rt.Dialer for ScriptedDialer with fn start_tls(self, conn, host~) {
  self.upgrades.push(host)
  conn
}

///|
/// The dialer operations as methods of the double.
pub extend ScriptedDialer with @rt.Dialer::{connect, start_tls}

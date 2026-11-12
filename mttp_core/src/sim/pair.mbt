///|
/// One direction of a SimConn pair.
priv struct Pipe {
  queue : Array[Bytes]
  mut pending : Bytes
  mut ended : Bool
  mut reader_closed : Bool
  mut changed : &@rt.Signal
}

///|
/// A fresh, empty direction whose signal comes from `coordination`.
fn Pipe::new(coordination : &@rt.Coordination) -> Pipe {
  {
    queue: [],
    pending: b"",
    ended: false,
    reader_closed: false,
    changed: coordination.signal(),
  }
}

///|
/// One end of an in-memory full-duplex connection made by `pair`. Writes
/// never block; reads are fragmented to at most `chunk_bytes`.
pub struct SimConn {
  priv input : Pipe
  priv output : Pipe
  priv coordination : &@rt.Coordination
  priv chunk_bytes : Int32
  priv mut closed : Bool
  priv mut close_count : Int32
}

///|
/// Two connected ends: what one writes, the other reads. `chunk_bytes`
/// (at least 1) caps every read in both directions, so a test can feed a
/// parser one byte at a time.
///
/// ```mbt check
/// test {
///   let d = @driver.Driver::new()
///   let (client, server) = @sim.pair(@sim.SimCoordination::new(d), chunk_bytes=2)
///   d.run(() => {
///     client.write(b"abc")
///     assert_eq(server.read(max_len=16), Some(b"ab"))
///     assert_eq(server.read(max_len=16), Some(b"c"))
///     client.close()
///     assert_eq(server.read(max_len=16), None)
///   })
/// }
/// ```
pub fn pair(
  coordination : &@rt.Coordination,
  chunk_bytes~ : Int32 = 65536,
) -> (SimConn, SimConn) {
  let left = Pipe::new(coordination)
  let right = Pipe::new(coordination)
  let chunk_bytes = chunk_bytes.max(1)
  (
    {
      input: left,
      output: right,
      coordination,
      chunk_bytes,
      closed: false,
      close_count: 0,
    },
    {
      input: right,
      output: left,
      coordination,
      chunk_bytes,
      closed: false,
      close_count: 0,
    },
  )
}

///|
/// Ends the outgoing stream only: the peer reads EOF, and this end still
/// reads. `rt.Conn` has no such operation; it exists to test how a peer
/// reacts to a half-closed stream.
pub fn SimConn::shutdown_write(self : SimConn) -> Unit {
  self.output.ended = true
  self.output.changed.notify()
}

///|
/// How many times the connection was closed: 0 or 1, however often `close`
/// is called, for exactly-once cleanup assertions.
pub fn SimConn::closes(self : SimConn) -> Int32 {
  self.close_count
}

///|
/// Reads queued bytes, at most `max_len` and the pair's `chunk_bytes`. A
/// nonpositive `max_len` raises `Invalid`.
pub impl @rt.Conn for SimConn with fn read(self, max_len~) {
  if max_len <= 0 {
    raise @mttp_core.TransportError(
      kind=Invalid,
      phase=Unknown,
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
/// Queues all of `bytes`. Raises `Network` after this end closed or shut
/// down its writes, or after the peer closed.
pub impl @rt.Conn for SimConn with fn write(self, bytes) {
  if self.closed || self.output.ended || self.output.reader_closed {
    raise @mttp_core.TransportError(
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
/// Closes both halves once, drops unread bytes and wakes a blocked reader;
/// the peer reads EOF.
pub impl @rt.Conn for SimConn with fn close(self) {
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
/// The connection operations as methods of the double.
pub extend SimConn with @rt.Conn::{read, write, close}

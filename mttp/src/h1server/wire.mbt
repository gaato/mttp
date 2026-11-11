// One accepted connection with the bytes read past the message being
// served. Every read is at most 64 KiB, and the engine never reads more
// than 64 KiB ahead while a request body is unclaimed, or one read after
// the body completes. `pending` holds at most 64 KiB.

///|
/// The largest single read or write on a connection.
let io_bytes : Int32 = 65536

///|
priv struct Wire {
  conn : &@rt.Conn
  timer : &@rt.Timer
  /// Bytes read from `conn` and not consumed yet: the start of the next
  /// pipelined request, or the rest of a body.
  mut pending : Bytes
}

///|
fn Wire::new(conn : &@rt.Conn, timer : &@rt.Timer) -> Wire {
  { conn, timer, pending: b"", }
}

///|
/// Pending bytes first, then a read of at most `max_len` from the
/// connection; `None` at EOF. Failures keep the connection's kind and
/// detail and take `phase`.
async fn Wire::read(
  self : Wire,
  max_len : Int32,
  phase : @mttp.Phase,
) -> Bytes? raise @mttp.TransportError {
  if !self.pending.is_empty() {
    let n = self.pending.length().min(max_len)
    let bytes = self.pending[:n].to_owned()
    self.pending = self.pending[n:].to_owned()
    return Some(bytes)
  }
  self.conn.read(max_len~) catch {
    @mttp.TransportError(kind~, detail~, ..) =>
      raise @mttp.TransportError(kind~, phase~, detail~)
  }
}

///|
/// Puts bytes back in front of the pending ones.
fn Wire::unread(self : Wire, bytes : BytesView) -> Unit {
  if !bytes.is_empty() {
    self.pending = bytes.to_owned() + self.pending
  }
}

///|
/// Writes `bytes` in slices of at most 64 KiB, each within `timeout_ms`.
/// Failures and expiry are reported in phase Write.
async fn Wire::write(
  self : Wire,
  bytes : BytesView,
  timeout_ms : Int32,
) -> Unit raise @mttp.TransportError {
  for offset = 0; offset < bytes.length(); {
    let end = offset + (bytes.length() - offset).min(io_bytes)
    let slice = bytes[offset:end].to_owned()
    within(
      self.timer,
      timeout_ms,
      timeout(timeout_ms, Write, "the response write"),
      () => self.conn.write(slice),
    ) catch {
      @mttp.TransportError(kind~, detail~, ..) =>
        raise @mttp.TransportError(kind~, phase=Write, detail~)
    }
    continue end
  }
}

///|
/// Runs `f` within `ms` milliseconds on `timer`: expiry cancels it and
/// raises `expired`, as does a nonpositive budget without starting it.
/// Cancellation from outside is not an `Error`, so it propagates untouched.
async fn[X] within(
  timer : &@rt.Timer,
  ms : Int32,
  expired : @mttp.TransportError,
  f : async () -> X raise @mttp.TransportError,
) -> X raise @mttp.TransportError {
  let mut outcome : Result[X, @mttp.TransportError]? = None
  let completed = timer.within(ms, () => {
    outcome = Some(Ok(f()) catch { error => Err(error) })
  })
  match outcome {
    Some(Ok(value)) if completed => value
    Some(Err(error)) if completed => raise error
    _ => raise expired
  }
}

///|
/// The error of a limit of `ms` that ran out while doing `what`.
fn timeout(
  ms : Int32,
  phase : @mttp.Phase,
  what : String,
) -> @mttp.TransportError {
  @mttp.TransportError(
    kind=Timeout(ms~),
    phase~,
    detail="\{what} exceeded \{ms} ms",
  )
}

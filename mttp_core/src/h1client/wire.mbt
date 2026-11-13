///|
/// The largest single read or write on a connection.
let io_bytes : Int32 = 65536

///|
/// One connection with the bytes read past the end of a message.
priv struct Wire {
  mut conn : &@rt.Conn
  /// Bytes read from `conn` and not consumed yet. A connection is parked
  /// only when this is empty: anything left over is unsolicited.
  mut pending : Bytes
  /// Bytes read from `conn` since the connection was last taken for an
  /// exchange; a reused connection that fails before any arrived may be
  /// stale.
  mut received : Int64
  /// Whether a write has started since the connection was last taken.
  mut wrote : Bool
  /// Whether the first write since the connection was last taken was
  /// refused with none of its bytes sent: nothing of the request reached
  /// the peer.
  mut refused : Bool
  mut closed : Bool
  /// When the connection was last parked, on the client's clock.
  mut parked_at : Int64
}

///|
fn Wire::new(conn : &@rt.Conn) -> Wire {
  {
    conn,
    pending: b"",
    received: 0L,
    wrote: false,
    refused: false,
    closed: false,
    parked_at: 0L,
  }
}

///|
/// Starts counting what an exchange on a parked connection reads and
/// writes.
fn Wire::reuse(self : Wire) -> Unit {
  self.received = 0L
  self.wrote = false
  self.refused = false
}

///|
/// A parked connection idle at least this long is checked before it is
/// reused. Servers close idle keep-alive connections after a few seconds
/// (Apache after 5, nginx after 75), and a request written to a connection
/// the server has already closed fails after it was sent, so a request that
/// may not be resent, such as a POST, would fail although the server never
/// saw it. Back-to-back reuse, which the pool exists for, skips the check:
/// no server closes a connection that soon after answering on it without
/// saying so.
let probe_after_ms : Int64 = 100L

///|
/// How long the check waits. A close or bytes the peer already sent are
/// there at once, so waiting longer only delays a healthy connection. It is
/// 2 and not 1 because core/async counts its timers in whole milliseconds:
/// a 1 ms wait ends at the next tick of the clock, which can be at once,
/// and its read was then cancelled before it saw a close already there. In
/// a loopback test against a server that had closed (TLS, close_notify then
/// FIN), 1 ms missed the close in 13 to 20 checks of 200, 2 ms in none,
/// also with every core busy. Over TLS such a cut-off read can leave the
/// session shut down without returning EOF; `Client::send_request` handles
/// the write the session then refuses.
let probe_ms : Int32 = 2

///|
/// Whether the peer closed the parked connection or sent something on it,
/// either of which makes it unusable: a read that finishes within
/// `probe_ms` finds them, and so does one that fails, `IncompleteClose`
/// among the failures. On a healthy connection there is nothing to read and
/// the read is cancelled.
async fn Wire::peer_gone(self : Wire, timer : &@rt.Timer) -> Bool noraise {
  timer.within(probe_ms, () => {
    let _ = self.conn.read(max_len=1) catch { _ => None }
  })
}

///|
/// Connects to `host:port`, upgrading to TLS when `secure`. A failed
/// upgrade closes the connection.
async fn Wire::dial(
  dialer : &@rt.Dialer,
  host : String,
  port : Int32,
  secure : Bool,
) -> Wire raise @mttp_core.TransportError {
  let wire = Wire::new(dialer.connect(host~, port~))
  errdefer wire.close()
  if secure {
    wire.conn = dialer.start_tls(wire.conn, host~)
  }
  wire
}

///|
/// Closes the connection once.
fn Wire::close(self : Wire) -> Unit {
  if !self.closed {
    self.closed = true
    self.pending = b""
    self.conn.close()
  }
}

///|
/// Writes `bytes`. A connection that raises `Closed` sent none of them
/// (`rt.Conn` promises it), so when that write was the first, `refused`
/// records that the peer got nothing. The failure is reported as `Network`:
/// the connection was closed, not the client.
async fn Wire::write(
  self : Wire,
  bytes : Bytes,
) -> Unit raise @mttp_core.TransportError {
  let first = !self.wrote
  self.wrote = true
  self.conn.write(bytes) catch {
    @mttp_core.TransportError(kind=Closed, phase~, detail~) => {
      self.refused = first
      raise @mttp_core.TransportError(kind=Network, phase~, detail~)
    }
    error => raise error
  }
}

///|
/// What a read of the wire found.
priv enum Read {
  /// A nonempty chunk.
  Data(Bytes)
  /// The end of the connection's read half. `clean` is false when the
  /// transport ended without its own end-of-stream signal
  /// (`IncompleteClose`: a TLS peer closed without close_notify). Where the
  /// framing delimits the message, either end is EOF; a body delimited by
  /// the close is truncated by an unclean one (RFC 9112, section 9.8).
  End(clean~ : Bool)
}

///|
/// Pending bytes first, then a read of at most `max_len` from the
/// connection.
async fn Wire::read(
  self : Wire,
  max_len : Int32,
) -> Read raise @mttp_core.TransportError {
  if !self.pending.is_empty() {
    let n = self.pending.length().min(max_len)
    let bytes = self.pending[:n].to_owned()
    self.pending = self.pending[n:].to_owned()
    return Data(bytes)
  }
  let read = self.conn.read(max_len~) catch {
    @mttp_core.TransportError(kind=IncompleteClose, ..) =>
      return End(clean=false)
    error => raise error
  }
  match read {
    Some(bytes) => {
      self.received += bytes.length().to_int64()
      Data(bytes)
    }
    None => End(clean=true)
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
/// Reads one response head within `limits`, leaving the bytes after it
/// pending. Every failure is one of `phase`: the end of the connection
/// first, clean or not, is `Network`, a read failure without a phase takes
/// `phase`, a codec error is `Protocol`.
async fn Wire::head(
  self : Wire,
  limits : @h1.Limits,
  phase~ : @mttp_core.Phase = Head,
) -> @h1.ParsedResponse raise @mttp_core.TransportError {
  let decoder = @h1.HeadDecoder::new(max=limits.max_head_bytes)
  for ;; {
    // A read failure is this head's, whoever runs it: inside a phase
    // timer or not, it reports `phase`.
    let read = self.read(io_bytes) catch {
      error => raise failure(phase, error)
    }
    // An unclean end is EOF here: the head delimits itself.
    let bytes = match read {
      Data(bytes) => bytes
      End(clean~) =>
        raise @mttp_core.TransportError(
          kind=Network,
          phase~,
          detail=if clean {
            "EOF before the response head"
          } else {
            "EOF before the response head, without TLS close_notify"
          },
        )
    }
    let result = decoder.feed(bytes) catch {
      error => raise failure(phase, error)
    }
    if result.head is Some(head) {
      self.unread(bytes[result.consumed:])
      return @h1.parse_response_head(head, limits~) catch {
        error => raise failure(phase, error)
      }
    }
  }
}

///|
/// Writes `bytes` in slices of at most 64 KiB, each under the Write limit.
async fn Wire::send(
  self : Wire,
  bytes : BytesView,
  timer : PhaseTimer,
) -> Unit raise @mttp_core.TransportError {
  for offset = 0; offset < bytes.length(); {
    let n = (bytes.length() - offset).min(io_bytes)
    let slice = bytes[offset:offset + n].to_owned()
    timer.run(Write, () => self.write(slice))
    continue offset + n
  }
}

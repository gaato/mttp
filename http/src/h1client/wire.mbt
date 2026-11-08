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
  mut closed : Bool
}

///|
fn Wire::new(conn : &@rt.Conn) -> Wire {
  { conn, pending: b"", received: 0L, closed: false, }
}

///|
/// Connects to `host:port`, upgrading to TLS when `secure`. A failed
/// upgrade closes the connection.
async fn Wire::dial(
  dialer : &@rt.Dialer,
  host : String,
  port : Int32,
  secure : Bool,
) -> Wire raise @http.TransportError {
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
async fn Wire::write(
  self : Wire,
  bytes : Bytes,
) -> Unit raise @http.TransportError {
  self.conn.write(bytes)
}

///|
/// Pending bytes first, then a read of at most `max_len` from the
/// connection.
async fn Wire::read(
  self : Wire,
  max_len : Int32,
) -> Bytes? raise @http.TransportError {
  if !self.pending.is_empty() {
    let n = self.pending.length().min(max_len)
    let bytes = self.pending[:n].to_owned()
    self.pending = self.pending[n:].to_owned()
    return Some(bytes)
  }
  let bytes = self.conn.read(max_len~)
  if bytes is Some(bytes) {
    self.received += bytes.length().to_int64()
  }
  bytes
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
/// pending. EOF first is a `Network` failure of `phase`.
async fn Wire::head(
  self : Wire,
  limits : @h1.Limits,
  phase~ : @http.Phase = Head,
) -> @h1.ParsedResponse raise @http.TransportError {
  let decoder = @h1.HeadDecoder::new(max=limits.max_head_bytes)
  for ;; {
    guard self.read(io_bytes) is Some(bytes) else {
      raise @http.TransportError(
        kind=Network,
        phase~,
        detail="EOF before the response head",
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
) -> Unit raise @http.TransportError {
  for offset = 0; offset < bytes.length(); {
    let n = (bytes.length() - offset).min(io_bytes)
    let slice = bytes[offset:offset + n].to_owned()
    timer.run(Write, () => self.write(slice))
    continue offset + n
  }
}

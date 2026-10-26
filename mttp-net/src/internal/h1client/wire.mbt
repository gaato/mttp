///|
pub(all) struct Wire {
  mut conn : &@connection.Conn
  mut pending : Bytes
  mut closed : Bool
}

///|
pub fn Wire::new(conn : &@connection.Conn) -> Wire {
  { conn, pending: b"", closed: false, }
}

///|
pub async fn Wire::dial(
  dialer : &@connection.Dialer,
  host : String,
  port : Int32,
  secure : Bool,
) -> Wire raise @model.TransportError {
  let wire = Wire::new(dialer.connect(host~, port~))
  errdefer wire.close()
  if secure {
    wire.conn = dialer.start_tls(wire.conn, host~)
  }
  wire
}

///|
pub fn Wire::close(self : Wire) -> Unit {
  if !self.closed {
    self.closed = true
    self.pending = b""
    self.conn.close()
  }
}

///|
pub async fn Wire::write(
  self : Wire,
  bytes : Bytes,
) -> Unit raise @model.TransportError {
  self.conn.write(bytes)
}

///|
pub async fn Wire::read(
  self : Wire,
  max_len : Int32,
) -> Bytes? raise @model.TransportError {
  if !self.pending.is_empty() {
    let n = self.pending.length().min(max_len)
    let bytes = self.pending[:n].to_owned()
    self.pending = self.pending[n:].to_owned()
    return Some(bytes)
  }
  self.conn.read(max_len~)
}

///|
pub fn Wire::unread(self : Wire, bytes : BytesView) -> Unit {
  if !bytes.is_empty() {
    self.pending = bytes.to_owned() + self.pending
  }
}

///|
pub async fn Wire::head(
  self : Wire,
  limits : @h1.Limits,
  phase~ : @model.Phase = Head,
) -> (@h1.Version, @model.ResponseHead) raise @model.TransportError {
  let decoder = @h1.HeadDecoder::new(max=limits.max_head_bytes)
  for ;; {
    guard self.read(65536) is Some(bytes) else {
      raise @model.TransportError(
        kind=Network,
        phase~,
        detail="EOF before response head",
      )
    }
    let result = decoder.feed(bytes) catch {
      error => raise failure(phase, error)
    }
    if result.head is Some(head) {
      self.unread(bytes[result.consumed:])
      let (v, status, headers) = @h1.parse_response_head(head, limits~) catch {
        error => raise failure(phase, error)
      }
      return (v, { status, headers, })
    }
  }
}

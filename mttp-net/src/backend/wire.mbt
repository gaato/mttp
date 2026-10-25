///|
priv struct Wire {
  tcp : @socket.Tcp
  tls : @tls.Tls?
  mut pending : Bytes
  mut closed : Bool
}

///|
async fn Wire::dial(host : String, port : Int32, secure : Bool) -> Wire {
  let tcp = @socket.Tcp::connect_to_host(host, port~)
  errdefer tcp.close()
  let tls = if secure {
    Some(@tls.Tls::client(tcp, host~, trust=SystemRoot))
  } else {
    None
  }
  { tcp, tls, pending: b"", closed: false, }
}

///|
fn Wire::close(self : Wire) -> Unit {
  if !self.closed {
    self.closed = true
    if self.tls is Some(tls) {
      tls.close()
    }
    self.tcp.close()
    self.pending = b""
  }
}

///|
async fn Wire::write(self : Wire, bytes : Bytes) -> Unit {
  match self.tls {
    Some(tls) => tls.write(bytes)
    None => self.tcp.write(bytes)
  }
}

///|
async fn Wire::read(self : Wire, max_len : Int32) -> Bytes? {
  if !self.pending.is_empty() {
    let n = self.pending.length().min(max_len)
    let bytes = self.pending[:n].to_owned()
    self.pending = self.pending[n:].to_owned()
    return Some(bytes)
  }
  match self.tls {
    Some(tls) => tls.read_some(max_len~)
    None => self.tcp.read_some(max_len~)
  }
}

///|
fn Wire::unread(self : Wire, bytes : BytesView) -> Unit {
  if !bytes.is_empty() {
    self.pending = bytes.to_owned() + self.pending
  }
}

///|
async fn Wire::head(
  self : Wire,
  limits : @h1.Limits,
) -> (@h1.Version, @model.ResponseHead) {
  let decoder = @h1.HeadDecoder::new(max=limits.max_head_bytes)
  for ;; {
    guard self.read(65536) is Some(bytes) else {
      raise @model.TransportError(
        kind=Network,
        phase=Head,
        detail="EOF before response head",
      )
    }
    let result = decoder.feed(bytes)
    if result.head is Some(head) {
      self.unread(bytes[result.consumed:])
      let (v, status, headers) = @h1.parse_response_head(head, limits~)
      return (v, { status, headers, })
    }
  }
}

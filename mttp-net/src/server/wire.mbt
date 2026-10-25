///|
priv struct Wire {
  tcp : @socket.Tcp
  mut pending : Bytes
  mut closed : Bool
}

///|
fn Wire::close(self : Wire) -> Unit {
  if !self.closed {
    self.closed = true
    self.pending = b""
    self.tcp.close()
  }
}

///|
async fn Wire::read(
  self : Wire,
  max_len~ : Int32 = 65536,
) -> Bytes? raise @model.TransportError {
  if !self.pending.is_empty() {
    let take = self.pending.length().min(max_len)
    let bytes = self.pending[:take].to_owned()
    self.pending = self.pending[take:].to_owned()
    return Some(bytes)
  }
  self.tcp.read_some(max_len~) catch {
    _ =>
      raise @model.TransportError(
        kind=Network,
        phase=Body,
        detail="socket read failed",
      )
  }
}

///|
fn Wire::unread(self : Wire, bytes : BytesView) -> Unit {
  if !bytes.is_empty() {
    self.pending = bytes.to_owned() + self.pending
  }
}

///|
async fn Wire::write(
  self : Wire,
  bytes : Bytes,
  timeout : Int32,
) -> Unit raise @model.TransportError {
  for offset = 0; offset < bytes.length(); {
    @async.with_timeout(timeout, () => {
      let end = offset + (bytes.length() - offset).min(65536)
      self.tcp.write(bytes[offset:end].to_owned())
    }) catch {
      @async.TimeoutError =>
        raise @model.TransportError(
          kind=Timeout(ms=timeout),
          phase=Write,
          detail="socket write timed out",
        )
      _ =>
        raise @model.TransportError(
          kind=Network,
          phase=Write,
          detail="socket write failed",
        )
    }
    continue offset + (bytes.length() - offset).min(65536)
  }
}

///|
async fn Wire::head(
  self : Wire,
  limits : ServerLimits,
) -> (@model.Method, String, @h1.Version, @model.Headers)? {
  @async.with_timeout(limits.header_timeout_ms, () => {
    let decoder = @h1.HeadDecoder::new(max=limits.max_header_bytes)
    let mut started = false
    for ;; {
      guard self.read() is Some(bytes) else {
        if started {
          ignore(decoder.finish())
        }
        return None
      }
      started = true
      let result = decoder.feed(bytes)
      if result.head is Some(head) {
        self.unread(bytes[result.consumed:])
        return Some(
          @h1.parse_request_head(head, limits={
            ..@h1.Limits::default(),
            max_head_bytes: limits.max_header_bytes,
          }),
        )
      }
    }
  }) catch {
    @async.TimeoutError =>
      raise @model.TransportError(
        kind=Timeout(ms=limits.header_timeout_ms),
        phase=Head,
        detail="request head timed out",
      )
    @model.TransportError(kind~, detail~, ..) =>
      raise @model.TransportError(kind~, phase=Head, detail~)
    error => raise error
  }
}

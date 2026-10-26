///|
using @config {type ServerLimits, type ServeError}

///|
pub(all) struct Wire {
  conn : &@connection.Conn
  clock : &@clock.Clock
  timer : &@clock.Timer
  coordination : &@connection.Coordination
  mut pending : Bytes
  mut closed : Bool
}

///|
pub fn Wire::new(
  conn : &@connection.Conn,
  clock~ : &@clock.Clock,
  timer~ : &@clock.Timer,
  coordination~ : &@connection.Coordination,
) -> Wire {
  { conn, clock, timer, coordination, pending: b"", closed: false, }
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
pub async fn[X] Wire::with_timeout(
  self : Wire,
  ms : Int32,
  f : async () -> X,
  error~ : @model.TransportError,
) -> X {
  let outcome : Ref[Result[X, Error]?] = Ref(None)
  let finished = self.timer.within(ms, () => {
    outcome.val = Some(Ok(f()) catch { error => Err(error) })
  })
  if !finished {
    raise error
  }
  match outcome.val {
    Some(Ok(value)) => value
    Some(Err(error)) => raise error
    None => raise error
  }
}

///|
pub async fn Wire::read(
  self : Wire,
  max_len~ : Int32 = 65536,
) -> Bytes? raise @model.TransportError {
  if self.closed {
    raise @model.TransportError(
      kind=Network,
      phase=Body,
      detail="connection closed",
    )
  }
  if !self.pending.is_empty() {
    let take = self.pending.length().min(max_len)
    let bytes = self.pending[:take].to_owned()
    self.pending = self.pending[take:].to_owned()
    return Some(bytes)
  }
  self.conn.read(max_len~) catch {
    @model.TransportError(kind~, detail~, ..) =>
      raise @model.TransportError(kind~, phase=Body, detail~)
  }
}

///|
pub fn Wire::unread(self : Wire, bytes : BytesView) -> Unit {
  if !bytes.is_empty() {
    self.pending = bytes.to_owned() + self.pending
  }
}

///|
pub async fn Wire::write(
  self : Wire,
  bytes : Bytes,
  timeout : Int32,
) -> Unit raise @model.TransportError {
  for offset = 0; offset < bytes.length(); {
    let end = offset + (bytes.length() - offset).min(65536)
    self.with_timeout(
      timeout,
      () => self.conn.write(bytes[offset:end].to_owned()),
      error=@model.TransportError(
        kind=Timeout(ms=timeout),
        phase=Write,
        detail="socket write timed out",
      ),
    ) catch {
      @model.TransportError(kind~, detail~, ..) =>
        raise @model.TransportError(kind~, phase=Write, detail~)
      error =>
        raise @model.TransportError(
          kind=Network,
          phase=Write,
          detail=error.to_string(),
        )
    }
    continue end
  }
}

///|
pub async fn Wire::head(
  self : Wire,
  limits : ServerLimits,
) -> (@model.Method, String, @h1.Version, @model.Headers)? {
  self.with_timeout(
    limits.header_timeout_ms,
    () => {
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
    },
    error=@model.TransportError(
      kind=Timeout(ms=limits.header_timeout_ms),
      phase=Head,
      detail="request head timed out",
    ),
  ) catch {
    @model.TransportError(kind~, detail~, ..) =>
      raise @model.TransportError(kind~, phase=Head, detail~)
    error => raise error
  }
}

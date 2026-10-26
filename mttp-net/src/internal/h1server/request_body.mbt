///|
pub(all) struct RequestBody {
  wire : Wire
  framing : @h1.Framing
  limits : ServerLimits
  decoder : @h1.ChunkedDecoder
  mut remaining : Int64
  mut count : Int64
  mut chunks : Array[Bytes]
  mut index : Int32
  mut done : Bool
  mut closed : Bool
  mut expect : Bool
  mut failure : @model.TransportError?
  changed : &@connection.Signal
  now : () -> Int64
  mut started_at : Int64?
}

///|
pub fn RequestBody::new(
  wire : Wire,
  framing : @h1.Framing,
  limits : ServerLimits,
  expect : Bool,
  now? : () -> Int64,
) -> RequestBody {
  {
    wire,
    framing,
    limits,
    decoder: @h1.ChunkedDecoder::new(@h1.Limits::default()),
    remaining: match framing {
      Length(n) => n
      _ => 0L
    },
    count: 0L,
    chunks: [],
    index: 0,
    done: framing is NoBody || framing == Length(0L),
    closed: false,
    expect,
    failure: None,
    changed: wire.coordination.signal(),
    now: now.unwrap_or(() => wire.clock.now_unix_ms()),
    started_at: None,
  }
}

///|
pub async fn RequestBody::next(
  self : RequestBody,
  max_len~ : Int32 = 65536,
) -> Bytes? raise @model.TransportError {
  if self.failure is Some(error) {
    raise error
  }
  let chunk = self.next_raw(max_len) catch {
    @model.TransportError(..) as error => {
      self.failure = Some(error)
      raise error
    }
  }
  if chunk is Some(bytes) {
    self.count += bytes.length().to_int64()
    if self.count > self.limits.max_body_bytes.to_int64() {
      let error = @model.TransportError(
        kind=TooLarge(limit=self.limits.max_body_bytes),
        phase=Body,
        detail="request body exceeds adapter ceiling",
      )
      self.failure = Some(error)
      raise error
    }
  }
  chunk
}

///|
pub fn RequestBody::budget(
  self : RequestBody,
) -> Int32 raise @model.TransportError {
  if self.done {
    return self.limits.body_timeout_ms
  }
  let now = (self.now)()
  let started = self.started_at.unwrap_or(now)
  self.started_at = Some(started)
  let elapsed = (now - started).max(0L)
  if elapsed >= self.limits.body_timeout_ms.to_int64() {
    raise @model.TransportError(
      kind=Timeout(ms=self.limits.body_timeout_ms),
      phase=Body,
      detail="request body timed out",
    )
  }
  self.limits.body_timeout_ms - elapsed.to_int()
}

///|
pub async fn RequestBody::next_raw(
  self : RequestBody,
  max_len : Int32,
) -> Bytes? raise @model.TransportError {
  for ;; {
    // A body owns one budget, including gaps between consumer pulls. Resetting
    // this for each socket read lets a trickling peer retain a slot indefinitely.
    let remaining_ms = self.budget()
    if self.index < self.chunks.length() {
      let bytes = self.chunks[self.index]
      self.index += 1
      return Some(bytes)
    }
    self.chunks.clear()
    self.index = 0
    if self.done {
      return None
    }
    if self.expect {
      self.wire.write(b"HTTP/1.1 100 Continue\r\n\r\n", remaining_ms)
      self.expect = false
    }
    let bytes = self.wire.with_timeout(
      self.budget(),
      () => self.wire.read(max_len~),
      error=@model.TransportError(
        kind=Timeout(ms=self.limits.body_timeout_ms),
        phase=Body,
        detail="request body timed out",
      ),
    ) catch {
      @model.TransportError(..) as error => raise error
      _ =>
        raise @model.TransportError(
          kind=Network,
          phase=Body,
          detail="request body read failed",
        )
    }
    guard bytes is Some(bytes) else {
      raise @model.TransportError(
        kind=Protocol,
        phase=Body,
        detail="truncated request body",
      )
    }
    match self.framing {
      Length(_) => {
        let take = bytes.length().to_int64().min(self.remaining).to_int()
        self.remaining -= take.to_int64()
        self.done = self.remaining == 0L
        if self.done {
          self.changed.notify()
        }
        self.wire.unread(bytes[take:])
        return Some(bytes[:take].to_owned())
      }
      Chunked => {
        let result = self.decoder.feed(bytes) catch {
          _ =>
            raise @model.TransportError(
              kind=Protocol,
              phase=Body,
              detail="invalid request chunk framing",
            )
        }
        self.chunks = result.chunks
        self.done = result.done
        if self.done {
          self.changed.notify()
        }
        self.wire.unread(bytes[result.consumed:])
      }
      _ => {
        self.done = true
        return None
      }
    }
  }
}

///|
pub extend RequestBody with @model.BodyStream::{read_some, close}

///|
pub impl @model.BodyStream for RequestBody with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer {
    self.closed = true
  }
  let chunk = self.next()
  if chunk is None {
    self.closed = true
  }
  chunk
}

///|
// Closing the application reader must still allow the server to send a final
// error response and drain a small unread body before deciding on reuse.
pub impl @model.BodyStream for RequestBody with fn close(self) {
  self.closed = true
}

///|
pub async fn RequestBody::drain(self : RequestBody) -> Bool noraise {
  if self.failure is Some(_) || self.expect {
    return false
  }
  let mut remaining = self.limits.drain_max_bytes
  for ;; {
    if remaining == 0 && (!self.done || self.index < self.chunks.length()) {
      return false
    }
    let chunk = self.next(max_len=remaining.min(65536).max(1)) catch {
      _ => return false
    }
    guard chunk is Some(bytes) else { return true }
    if bytes.length() > remaining {
      return false
    }
    remaining -= bytes.length()
  }
}

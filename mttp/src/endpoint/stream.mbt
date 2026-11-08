///|
priv struct BufferedStream {
  bytes : Bytes
  mut offset : Int32
  mut closed : Bool
}

///|
fn BufferedStream::new(bytes : Bytes) -> BufferedStream {
  { bytes, offset: 0, closed: false, }
}

///|
impl @http.BodyStream for BufferedStream with fn read_some(self) {
  if self.closed || self.offset == self.bytes.length() {
    return None
  }
  let end = self.offset + (self.bytes.length() - self.offset).min(65536)
  let chunk = self.bytes[self.offset:end].to_owned()
  self.offset = end
  Some(chunk)
}

///|
impl @http.BodyStream for BufferedStream with fn close(self) {
  self.closed = true
}

///|
priv struct ResponseOwner {
  reader : &@http.BodyStream
  request : @http.Body
  mut closed : Bool
}

///|
impl @http.BodyStream for ResponseOwner with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @http.BodyStream::close(self)
  let chunk = self.reader.read_some()
  if chunk is None {
    @http.BodyStream::close(self)
  }
  chunk
}

///|
impl @http.BodyStream for ResponseOwner with fn close(self) {
  if !self.closed {
    self.closed = true
    self.reader.close()
    discard(self.request)
  }
}

///|
priv struct LimitedInput {
  reader : &@http.BodyStream
  limit : Int32
  mut count : Int64
  failure : Ref[@schema.DecodeFailure?]
  mut closed : Bool
}

///|
impl @http.BodyStream for LimitedInput with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @http.BodyStream::close(self)
  let chunk = self.reader.read_some() catch {
    @http.TransportError(..) as error => {
      let @http.TransportError(kind~, ..) = error
      self.failure.val = Some(
        @schema.DecodeFailure(
          kind=match kind {
            TooLarge(limit~) => @schema.TooLarge(limit~)
            _ => @schema.Malformed
          },
          message="request body could not be read",
        ),
      )
      raise error
    }
  }
  if chunk is Some(bytes) {
    if bytes.length().to_int64() > self.limit.to_int64() - self.count {
      self.failure.val = Some(
        @schema.DecodeFailure(
          kind=TooLarge(limit=self.limit),
          message="request body exceeds limit",
        ),
      )
      raise @http.TransportError(
        kind=TooLarge(limit=self.limit),
        phase=Body,
        detail="request body exceeds limit",
      )
    }
    self.count += bytes.length().to_int64()
  } else {
    @http.BodyStream::close(self)
  }
  chunk
}

///|
impl @http.BodyStream for LimitedInput with fn close(self) {
  if !self.closed {
    self.closed = true
    self.reader.close()
  }
}

///|
/// Supplies an explicit request-dependent limiter bucket. Without this
/// builder the client uses its default bucket, independently of operation_id.
pub fn[S, I, E, O, M] Endpoint::rate_limit_bucket(
  self : Endpoint[S, I, E, O, M],
  f : (@http.Request) -> String,
) -> Endpoint[S, I, E, O, M] {
  { ..self, bucket: Some(f), }
}

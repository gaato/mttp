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
impl @model.BodyStream for BufferedStream with fn read_some(self) {
  if self.closed || self.offset == self.bytes.length() {
    return None
  }
  let end = self.offset + (self.bytes.length() - self.offset).min(65536)
  let chunk = self.bytes[self.offset:end].to_owned()
  self.offset = end
  Some(chunk)
}

///|
impl @model.BodyStream for BufferedStream with fn close(self) {
  self.closed = true
}

///|
priv struct ResponseOwner {
  reader : &@model.BodyStream
  request : @model.Body
  mut closed : Bool
}

///|
impl @model.BodyStream for ResponseOwner with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @model.BodyStream::close(self)
  let chunk = self.reader.read_some()
  if chunk is None {
    @model.BodyStream::close(self)
  }
  chunk
}

///|
impl @model.BodyStream for ResponseOwner with fn close(self) {
  if !self.closed {
    self.closed = true
    self.reader.close()
    discard(self.request)
  }
}

///|
priv struct LimitedInput {
  reader : &@model.BodyStream
  limit : Int32
  mut count : Int64
  failure : Ref[@schema.DecodeFailure?]
  mut closed : Bool
}

///|
impl @model.BodyStream for LimitedInput with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @model.BodyStream::close(self)
  let chunk = self.reader.read_some() catch {
    @model.TransportError(..) as error => {
      self.failure.val = Some(
        @schema.DecodeFailure(
          kind=Malformed,
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
      raise @model.TransportError(
        kind=TooLarge(limit=self.limit),
        phase=Body,
        detail="request body exceeds limit",
      )
    }
    self.count += bytes.length().to_int64()
  } else {
    @model.BodyStream::close(self)
  }
  chunk
}

///|
impl @model.BodyStream for LimitedInput with fn close(self) {
  if !self.closed {
    self.closed = true
    self.reader.close()
  }
}

///|
/// Supplies an explicit request-dependent limiter bucket. Without this
/// builder the client uses its default bucket, independently of operation_id.
pub fn[S, I, E, O] Endpoint::rate_limit_bucket(
  self : Endpoint[S, I, E, O],
  f : (@model.Request) -> String,
) -> Endpoint[S, I, E, O] {
  { ..self, bucket: Some(f), }
}

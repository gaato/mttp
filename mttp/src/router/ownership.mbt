///|
// Middleware may return a lazy response which consumes the original body.
// Keep that body alive even when middleware never invokes its next handler.
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

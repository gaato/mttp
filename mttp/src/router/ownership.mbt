///|
// Middleware may return a lazy response which consumes the original body.
// Keep that body alive even when middleware never invokes its next handler.
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

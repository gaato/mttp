///|
// Keep stream cleanup idempotent across EOF, failure and the engine's final
// response.close. Fixed bodies need no wrapper: the engine acknowledges
// completion after their final write, so they retain their direct path.
priv struct ResponseLease {
  body : @mttp_core.StreamBody
  mut reader : &@mttp_core.BodyStream?
  mut closed : Bool
}

///|
impl @mttp_core.BodyStream for ResponseLease with fn read_some(self) {
  if self.closed {
    return None
  }
  let reader = match self.reader {
    Some(reader) => reader
    None => {
      let reader = self.body.take()
      self.reader = Some(reader)
      reader
    }
  }
  reader.read_some()
}

///|
impl @mttp_core.BodyStream for ResponseLease with fn close(self) {
  if !self.closed {
    self.closed = true
    match self.reader {
      Some(reader) => reader.close()
      None => self.body.close()
    }
  }
}

///|
fn lease(response : @mttp_core.Response) -> @mttp_core.Response {
  // Upgrade writes close the HTTP body only once before handing over the
  // connection; they do not need the ordinary streaming cleanup wrapper.
  if response.status == 101 && response.attributes.get(@rt.upgrade) is Some(_) {
    return response
  }
  guard response.body is Stream(body) else { return response }
  {
    ..response,
    body: Stream(
      @mttp_core.StreamBody::new(
        ResponseLease::{ body, reader: None, closed: false, },
        length?=body.length(),
      ),
    ),
  }
}

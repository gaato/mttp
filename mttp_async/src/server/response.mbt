///|
// The engine closes every response after writing it (also for HEAD/204 and
// failures). A private body lease therefore tracks the whole response, not
// just the handler call, without adding runtime hooks to the portable engine.
priv struct ResponseLease {
  body : @mttp.Body
  done : () -> Unit
  mut reader : &@mttp.BodyStream?
  mut sent : Bool
  mut closed : Bool
}

///|
impl @mttp.BodyStream for ResponseLease with fn read_some(self) {
  if self.closed {
    return None
  }
  match self.body {
    Stream(cell) => {
      let reader = match self.reader {
        Some(reader) => reader
        None => {
          let reader = cell.take()
          self.reader = Some(reader)
          reader
        }
      }
      reader.read_some()
    }
    _ => {
      if self.sent {
        return None
      }
      self.sent = true
      match self.body.as_bytes() {
        Some(bytes) if !bytes.is_empty() => Some(bytes)
        _ => None
      }
    }
  }
}

///|
impl @mttp.BodyStream for ResponseLease with fn close(self) {
  if !self.closed {
    self.closed = true
    match self.reader {
      Some(reader) => reader.close()
      None => if self.body is Stream(cell) { cell.close() }
    }
    (self.done)()
  }
}

///|
fn lease(
  response : @mttp.Response,
  meth : @mttp.Method,
  done : () -> Unit,
) -> @mttp.Response {
  {
    ..response,
    body: Stream(
      @mttp.StreamBody::new(
        ResponseLease::{
          body: response.body,
          done,
          reader: None,
          sent: false,
          closed: false,
        },
        // Empty on HEAD/304 describes no representation length. Keep the
        // engine's NoBody framing instead of inventing Content-Length: 0.
        length?=if response.body is Empty &&
          (meth == Head || response.status == 304) {
          None
        } else {
          response.body.length()
        },
      ),
    ),
  }
}

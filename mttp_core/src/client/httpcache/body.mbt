///|
fn source(
  body : @mttp_core.Body,
) -> (async () -> Bytes? raise @mttp_core.TransportError, () -> Unit) raise @mttp_core.TransportError {
  match body {
    Stream(stream) => {
      let s = stream.take()
      (() => s.read_some(), () => s.close())
    }
    Empty => (() => None, () => ())
    Bytes(bytes) => {
      let pending = Ref(true)
      (
        () => {
          if pending.val && !bytes.is_empty() {
            pending.val = false
            Some(bytes)
          } else {
            None
          }
        },
        () => pending.val = false,
      )
    }
    @mttp_core.Body::.. =>
      raise @mttp_core.TransportError(
        kind=Invalid,
        phase=Body,
        detail="unsupported cache body",
      )
  }
}

///|
priv struct Collected {
  read : async () -> Bytes? raise @mttp_core.TransportError
  close_ : () -> Unit
  mut buffer : Buffer
  limit : Int32
  mut over : Bool
  mut closed : Bool
  commit : async (Bytes) -> Unit noraise
}

///|
impl @mttp_core.BodyStream for Collected with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @mttp_core.BodyStream::close(self)
  let chunk = (self.read)()
  match chunk {
    Some(bytes) =>
      if !self.over {
        if bytes.length() > self.limit - self.buffer.length() {
          self.over = true
          self.buffer = Buffer(capacity=0)
        } else {
          self.buffer.write_bytes(bytes)
        }
      }
    None => {
      // Close transport before a potentially suspending store operation.
      let bytes = self.buffer.to_bytes()
      @mttp_core.BodyStream::close(self)
      if !self.over {
        (self.commit)(bytes)
      }
    }
  }
  chunk
}

///|
impl @mttp_core.BodyStream for Collected with fn close(self) {
  if !self.closed {
    self.closed = true
    self.buffer = Buffer(capacity=0)
    (self.close_)()
  }
}

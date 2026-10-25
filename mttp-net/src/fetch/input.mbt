///|
priv struct Input {
  reader : Reader
  limit : Int32
  mut count : Int32
  mut pending : Bytes
  mut offset : Int32
  mut closed : Bool
  mut failure : @model.TransportError?
  mut declared : Int64?
}

///|
fn Input::close(self : Input) -> Unit {
  if !self.closed {
    self.closed = true
    self.pending = b""
    self.reader.close()
  }
}

///|
impl @model.BodyStream for Input with fn close(self) {
  self.close()
}

///|
impl @model.BodyStream for Input with fn read_some(self) {
  if self.failure is Some(error) {
    raise error
  }
  if self.closed {
    return None
  }
  errdefer self.close()
  try {
    if self.pending.is_empty() {
      for empty = 0; ; empty = empty + 1 {
        if empty >= 1024 {
          raise @model.TransportError(
            kind=Protocol,
            phase=Body,
            detail="too many empty request chunks",
          )
        }
        let chunk = @js_async.run_promise(signal => self.reader.read(signal))
        if chunk.done {
          if self.declared is Some(length) && length != self.count.to_int64() {
            raise @model.TransportError(
              kind=Protocol,
              phase=Body,
              detail="request length mismatch",
            )
          }
          self.close()
          return None
        }
        if chunk.value.is_empty() {
          continue
        }
        if chunk.value.length() > self.limit - self.count {
          raise @model.TransportError(
            kind=TooLarge(limit=self.limit),
            phase=Body,
            detail="request body exceeds adapter ceiling",
          )
        }
        self.count += chunk.value.length()
        if self.declared is Some(length) && self.count.to_int64() > length {
          raise @model.TransportError(
            kind=Protocol,
            phase=Body,
            detail="request length mismatch",
          )
        }
        self.pending = chunk.value
        break
      }
    }
    let end = self.offset + (self.pending.length() - self.offset).min(65536)
    let bytes = self.pending[self.offset:end].to_owned()
    self.offset = end
    if end == self.pending.length() {
      self.pending = b""
      self.offset = 0
    }
    Some(bytes)
  } catch {
    error => {
      let failure = match error {
        @model.TransportError(..) as error => error
        _ =>
          @model.TransportError(
            kind=Network,
            phase=Body,
            detail="host request stream failed",
          )
      }
      self.failure = Some(failure)
      raise failure
    }
  }
}

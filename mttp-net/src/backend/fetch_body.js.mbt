///|
priv struct FetchBody {
  driver : FetchDriver
  key : String
  reader : FetchReader
  abort : @js_async.AbortController
  timer : PhaseTimer
  limit : Int32?
  mut count : Int64
  mut pending : Bytes
  mut offset : Int32
  mut closed : Bool
  mut busy : Bool
}

///|
fn FetchBody::close(self : FetchBody) -> Unit {
  if !self.closed {
    self.closed = true
    self.abort.abort()
    self.reader.close()
    self.pending = b""
    self.driver.slots.release(self.key)
  }
}

///|
impl @model.BodyStream for FetchBody with fn close(self) {
  self.close()
}

///|
impl @model.BodyStream for FetchBody with fn read_some(self) {
  if self.closed {
    return None
  }
  if self.busy {
    raise @model.TransportError(
      kind=Invalid,
      phase=Body,
      detail="concurrent body read",
    )
  }
  self.busy = true
  defer {
    self.busy = false
  }
  errdefer self.close()
  self.timer.run(Body, () => {
    if self.pending.is_empty() {
      for empty = 0; ; empty = empty + 1 {
        if empty >= 1024 {
          raise @model.TransportError(
            kind=Protocol,
            phase=Body,
            detail="too many empty fetch chunks",
          )
        }
        let chunk = self.reader
          .read(self.abort.signal())
          .wait(abort_controller=self.abort)
        if chunk.done {
          self.close()
          return None
        }
        if chunk.value.is_empty() {
          continue
        }
        if self.limit is Some(limit) {
          if chunk.value.length().to_int64() > limit.to_int64() - self.count {
            raise @model.TransportError(
              kind=TooLarge(limit~),
              phase=Body,
              detail="decoded body exceeds limit",
            )
          }
          self.count += chunk.value.length().to_int64()
        }
        self.pending = chunk.value
        break
      }
    }
    let n = (self.pending.length() - self.offset).min(65536)
    let bytes = self.pending[self.offset:self.offset + n].to_owned()
    self.offset += n
    if self.offset == self.pending.length() {
      self.pending = b""
      self.offset = 0
    }
    Some(bytes)
  })
}

///|
priv struct FetchBody {
  reader : FetchReader
  abort : @js_async.AbortController
  timer : FetchTimer
  limit : Int32?
  mut count : Int64
  mut pending : Bytes
  mut offset : Int32
  mut closed : Bool
}

///|
fn FetchBody::close(self : FetchBody) -> Unit {
  if !self.closed {
    self.closed = true
    self.abort.abort()
    self.reader.close()
    self.pending = b""
  }
}

///|
impl @mttp_core.BodyStream for FetchBody with fn close(self) {
  self.close()
}

///|
impl @mttp_core.BodyStream for FetchBody with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer self.close()
  self.timer.run(Body, () => {
    if self.pending.is_empty() {
      for empty = 0; ; empty = empty + 1 {
        if empty >= 1024 {
          raise @mttp_core.TransportError(
            kind=Protocol,
            phase=Body,
            detail="too many empty fetch chunks",
          )
        }
        // Keep the host reader visible here: core's ReadableStream wrapper
        // skips empty chunks without a budget, so cannot enforce this bound.
        let chunk = @js_async.run_promise(signal => self.reader.read(signal))
        if self.closed {
          return None
        }
        if chunk.done {
          self.close()
          return None
        }
        if chunk.value.is_empty() {
          continue
        }
        if self.limit is Some(limit) {
          if chunk.value.length().to_int64() > limit.to_int64() - self.count {
            raise @mttp_core.TransportError(
              kind=TooLarge(limit~),
              phase=Body,
              detail="fetch body exceeds limit",
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

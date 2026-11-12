///|
/// The request body as the handler reads it. The host body is locked to a
/// reader only on the first read, and closing only unlocks it again: the
/// adapter never cancels it, so the host keeps what is left of a body the
/// handler did not read to its end. wrangler dev, for one, forwards each
/// request to the Worker through a proxy worker and drains a body the Worker
/// left unused once the handler has answered, but skips a body that was
/// cancelled or is still locked. With wrangler 4.126.0 an upload that had
/// not finished then stayed half forwarded; once the response was sent,
/// workerd logged "Can't read from request stream after response has been
/// sent" and the next request on the connection failed with "Network
/// connection lost". Cancelling a body discarded unread, as an endpoint does
/// when authentication fails before it reads the body, did exactly that.
/// wrangler 4.160.1 no longer fails so, but no host needs the cancel.
priv struct Input {
  request : JsRequest
  mut reader : Reader?
  limit : Int32
  mut count : Int32
  mut pending : Bytes
  mut offset : Int32
  mut closed : Bool
  mut failure : @mttp_core.TransportError?
  mut declared : Int64?
}

///|
fn Input::close(self : Input) -> Unit {
  if !self.closed {
    self.closed = true
    self.pending = b""
    if self.reader is Some(reader) {
      reader.close()
    }
  }
}

///|
fn Input::reader(self : Input) -> Reader {
  match self.reader {
    Some(reader) => reader
    None => {
      let reader = self.request.reader()
      self.reader = Some(reader)
      reader
    }
  }
}

///|
impl @mttp_core.BodyStream for Input with fn close(self) {
  self.close()
}

///|
impl @mttp_core.BodyStream for Input with fn read_some(self) {
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
          raise @mttp_core.TransportError(
            kind=Protocol,
            phase=Body,
            detail="too many empty request chunks",
          )
        }
        let reader = self.reader()
        let chunk = @js_async.run_promise(signal => reader.read(signal))
        if chunk.done {
          if self.declared is Some(length) && length != self.count.to_int64() {
            raise @mttp_core.TransportError(
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
          raise @mttp_core.TransportError(
            kind=TooLarge(limit=self.limit),
            phase=Body,
            detail="request body exceeds adapter ceiling",
          )
        }
        self.count += chunk.value.length()
        if self.declared is Some(length) && self.count.to_int64() > length {
          raise @mttp_core.TransportError(
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
        @mttp_core.TransportError(..) as error => error
        _ =>
          @mttp_core.TransportError(
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

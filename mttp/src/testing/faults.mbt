///|
/// Fails the first `times` sends before entering the inner backend, then
/// forwards normally. The wrapper validates input and forwards close once.
/// Negative counts inject no failures. The supplied error determines the
/// failure phase, allowing unsent and possibly-sent retry cases.
pub fn fail_sends(
  inner : &@http.Backend,
  error : @http.TransportError,
  times~ : Int32 = 1,
) -> &@http.Backend {
  let remaining = Ref(times.max(0))
  @client.from_fn(
    (request, options) => {
      if remaining.val > 0 {
        remaining.val -= 1
        raise error
      }
      inner.send(request, options)
    },
    on_close=() => inner.close(),
  )
}

///|
priv struct FaultStream {
  source : &@http.BodyStream
  error : @http.TransportError
  mut remaining : Int32
  mut closed : Bool
}

///|
impl @http.BodyStream for FaultStream with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @http.BodyStream::close(self)
  if self.remaining == 0 {
    raise self.error
  }
  match self.source.read_some() {
    None => {
      @http.BodyStream::close(self)
      None
    }
    Some(chunk) => {
      if chunk.is_empty() {
        raise @http.TransportError(
          kind=Protocol,
          phase=Body,
          detail="empty source chunk",
        )
      }
      let take = self.remaining.min(chunk.length())
      self.remaining -= take
      Some(chunk[:take].to_owned())
    }
  }
}

///|
impl @http.BodyStream for FaultStream with fn close(self) {
  if !self.closed {
    self.closed = true
    self.source.close()
  }
}

///|
/// Injects a failure on the read after exactly `after_bytes` bytes have been
/// returned. A crossing chunk is cut; its unused suffix is discarded. Earlier
/// EOF or source error wins. The wrapper owns and closes the source on EOF,
/// failure, cancellation and explicit close, with sticky EOF afterwards.
pub fn fail_after(
  source : &@http.BodyStream,
  after_bytes : Int32,
  error : @http.TransportError,
) -> &@http.BodyStream raise @http.TransportError {
  if after_bytes < 0 {
    source.close()
    raise @http.TransportError(
      kind=Invalid,
      phase=Body,
      detail="negative fault offset",
    )
  }
  FaultStream::{ source, error, remaining: after_bytes, closed: false, }
}

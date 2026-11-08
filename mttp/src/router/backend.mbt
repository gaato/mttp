///|
/// In-process transport strips local attributes, validates SendOptions, and
/// transfers bodies by pull. Timed sends require clock and timer ports at
/// construction, since this portable package has no scheduler of its own.
pub impl @http.Backend for Router with fn send(self, request, options) {
  let mut transferred = false
  defer (if !transferred { discard(request.body) })
  if self.closed {
    raise @http.TransportError(kind=Closed, phase=Pool, detail="router closed")
  }
  request.validate()
  options.validate()
  let idle = match options.body {
    Stream(idle_ms~) => idle_ms
    _ => None
  }
  if (options.timeout_ms is Some(_) || idle is Some(_)) &&
    (self.clock is None || self.timer is None) {
    raise @http.TransportError(
      kind=Invalid,
      phase=Pool,
      detail="timed router sends require clock and timer",
    )
  }
  let start = self.clock.map(c => c.now_unix_ms()).unwrap_or(0L)
  let response = timed(self.timer, options.timeout_ms, Head, () => {
    let body = match request.body {
      Stream(body) => {
        let reader = body.take()
        let first = reader.read_some()
        @http.Body::Stream(
          @http.StreamBody::new(
            Prefetched::{ reader, first, closed: false, },
            length?=body.length(),
          ),
        )
      }
      body => body
    }
    self.dispatch({
      ..request,
      body,
      url: @http.join_url("http://in-process", request.url),
      attributes: @http.Attributes::empty().put(@http.remote_addr, "in-process"),
    })
  })
  transferred = true
  errdefer response.close()
  let (cap, timeout) = match options.body {
    Exchange(max_bytes~) => (Some(max_bytes), options.timeout_ms)
    _ => (None, None)
  }
  let body = match response.body {
    Bytes(bytes) => {
      if cap is Some(limit) && bytes.length() > limit {
        raise @http.TransportError(
          kind=TooLarge(limit~),
          phase=Body,
          detail="in-process response exceeds limit",
        )
      }
      response.body
    }
    Stream(stream) =>
      @http.Stream(
        @http.StreamBody::new(
          BackendBody::{
            reader: stream.take(),
            clock: self.clock,
            timer: self.timer,
            start,
            timeout,
            idle,
            cap,
            read: 0,
            closed: false,
          },
          length?=stream.length(),
        ),
      )
    body => body
  }
  { ..response, body, attributes: @http.Attributes::empty(), }
}

///|
async fn[T] timed(
  timer : &@rt.Timer?,
  ms : Int32?,
  phase : @http.Phase,
  f : async () -> T raise @http.TransportError,
) -> T raise @http.TransportError {
  guard ms is Some(ms) && timer is Some(timer) else { return f() }
  let mut result : Result[T, @http.TransportError] = Err(
    @http.TransportError(
      kind=Timeout(ms~),
      phase~,
      detail="in-process deadline",
    ),
  )
  let completed = timer.within(ms, () => {
    result = Ok(f()) catch { error => Err(error) }
  })
  if !completed {
    raise @http.TransportError(
      kind=Timeout(ms~),
      phase~,
      detail="in-process deadline",
    )
  }
  match result {
    Ok(value) => value
    Err(error) => raise error
  }
}

///|
priv struct Prefetched {
  reader : &@http.BodyStream
  mut first : Bytes?
  mut closed : Bool
}

///|
impl @http.BodyStream for Prefetched with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @http.BodyStream::close(self)
  if self.first is Some(first) {
    self.first = None
    return Some(first)
  }
  let chunk = self.reader.read_some()
  if chunk is None {
    @http.BodyStream::close(self)
  }
  chunk
}

///|
impl @http.BodyStream for Prefetched with fn close(self) {
  if !self.closed {
    self.closed = true
    self.first = None
    self.reader.close()
  }
}

///|
priv struct BackendBody {
  reader : &@http.BodyStream
  clock : &@rt.Clock?
  timer : &@rt.Timer?
  start : Int64
  timeout : Int32?
  idle : Int32?
  cap : Int32?
  mut read : Int32
  mut closed : Bool
}

///|
impl @http.BodyStream for BackendBody with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @http.BodyStream::close(self)
  let mut ms = self.idle
  if self.timeout is Some(total) && self.clock is Some(clock) {
    let elapsed = (clock.now_unix_ms() - self.start).max(0L)
    let left = if elapsed >= total.to_int64() {
      0
    } else {
      total - elapsed.to_int()
    }
    ms = Some(left)
  }
  let chunk = timed(self.timer, ms, Body, () => self.reader.read_some())
  if chunk is Some(bytes) {
    if self.cap is Some(limit) {
      if bytes.length() > limit - self.read {
        raise @http.TransportError(
          kind=TooLarge(limit~),
          phase=Body,
          detail="in-process response exceeds limit",
        )
      }
      self.read += bytes.length()
    }
  } else {
    @http.BodyStream::close(self)
  }
  chunk
}

///|
impl @http.BodyStream for BackendBody with fn close(self) {
  if !self.closed {
    self.closed = true
    self.reader.close()
  }
}

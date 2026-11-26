///|
// Every handler boundary owns its incoming body, including bodies replaced
// upstream. A lazy response may still consume it, so transfer cleanup to that
// response instead of closing the input as soon as the head is returned.
async fn with_owned_request(
  request : @mttp_core.Request,
  handler : @mttp_core.Handler,
) -> @mttp_core.Response noraise {
  let mut transferred = false
  defer (if !transferred { discard(request.body) })
  let response = handler(request)
  if response.body is Stream(stream) {
    let reader = stream.take() catch {
      _ => {
        response.close()
        return problem(500, "Internal Server Error")
      }
    }
    let owned : &@mttp_core.BodyStream = ResponseOwner::{
      reader,
      request: request.body,
      closed: false,
      ended: false,
    }
    transferred = true
    return {
      ..response,
      body: Stream(@mttp_core.StreamBody::new(owned, length?=stream.length())),
    }
  }
  response
}

///|
priv struct ResponseOwner {
  reader : &@mttp_core.BodyStream
  request : @mttp_core.Body
  mut closed : Bool
  /// It returned EOF itself: its source's end may come before its own
  /// (bytes still to hand out) or be refused there, and trailers are the
  /// wrapper's only at its own end.
  mut ended : Bool
}

///|
impl @mttp_core.BodyStream for ResponseOwner with fn trailers(self) {
  if self.ended {
    self.reader.trailers()
  } else {
    @mttp_core.Headers::empty()
  }
}

///|
impl @mttp_core.BodyStream for ResponseOwner with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @mttp_core.BodyStream::close(self)
  let chunk = self.reader.read_some()
  if chunk is None {
    self.ended = true
    @mttp_core.BodyStream::close(self)
  }
  chunk
}

///|
impl @mttp_core.BodyStream for ResponseOwner with fn close(self) {
  if !self.closed {
    self.closed = true
    self.reader.close()
    discard(self.request)
  }
}

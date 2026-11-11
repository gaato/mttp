///|
// Every handler boundary owns its incoming body, including bodies replaced
// upstream. A lazy response may still consume it, so transfer cleanup to that
// response instead of closing the input as soon as the head is returned.
async fn with_owned_request(
  request : @mttp.Request,
  handler : @mttp.Handler,
) -> @mttp.Response noraise {
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
    let owned : &@mttp.BodyStream = ResponseOwner::{
      reader,
      request: request.body,
      closed: false,
    }
    transferred = true
    return {
      ..response,
      body: Stream(@mttp.StreamBody::new(owned, length?=stream.length())),
    }
  }
  response
}

///|
priv struct ResponseOwner {
  reader : &@mttp.BodyStream
  request : @mttp.Body
  mut closed : Bool
}

///|
impl @mttp.BodyStream for ResponseOwner with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer @mttp.BodyStream::close(self)
  let chunk = self.reader.read_some()
  if chunk is None {
    @mttp.BodyStream::close(self)
  }
  chunk
}

///|
impl @mttp.BodyStream for ResponseOwner with fn close(self) {
  if !self.closed {
    self.closed = true
    self.reader.close()
    discard(self.request)
  }
}

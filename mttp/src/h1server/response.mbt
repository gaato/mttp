// Writing the handler's response: framing from the body and the request
// method (`write_response_head` with `meth~` keeps HEAD, 204 and 304
// bodiless), a stream's first read before the head so a failing producer can
// still be answered with 500, and every write sliced to 64 KiB under the
// body deadline.

///|
/// Writes `response` to a request of `meth` and closes its body; `true` when
/// the connection may carry the next request. Sets `sent` once the head is
/// on its way, so that a failure before it can still be answered.
async fn Session::write_response(
  self : Session,
  response : @http.Response,
  source : RequestBody,
  meth : @http.Method,
  version : @h1.Version,
  close : Bool,
  sent : Ref[Bool],
) -> Bool raise @http.TransportError {
  defer response.close()
  let status = response.status
  if status < 200 || status > 599 {
    raise invalid_response("the handler returned status \{status}")
  }
  let bodiless = meth == Head || status == 204 || status == 304
  let framing : @h1.Framing = match response.body {
    _ if status == 204 => NoBody
    Empty => NoBody
    Bytes(bytes) => Length(bytes.length().to_int64())
    Stream(stream) =>
      match stream.length() {
        Some(n) => Length(n)
        // A HEAD or 304 response describes a body it does not send; with no
        // length to describe, it describes none.
        None if bodiless => NoBody
        None if version == Http10 => UntilClose
        None => Chunked
      }
    @http.Body::.. => raise invalid_response("unsupported response body")
  }
  let close = close || framing is UntilClose
  let headers = if close {
    response.headers.set("connection", "close")
  } else if version == Http10 {
    response.headers.set("connection", "keep-alive")
  } else {
    response.headers
  }
  let reader = match response.body {
    Stream(stream) if !bodiless => Some(stream.take())
    _ => None
  }
  let limit = self.limits.body_timeout_ms
  let first = match reader {
    Some(reader) => {
      let first = self.produce(reader)
      // A producer may catch a request-body failure before the head is
      // written. The malformed input must still determine the response.
      if source.failure is Some(error) {
        raise error
      }
      first
    }
    None => None
  }
  // The status line names HTTP/1.1, the version this server implements,
  // also to an HTTP/1.0 client (RFC 9110, section 6.2); the framing above
  // already keeps to what that client reads.
  let head = @h1.write_response_head(status, headers, framing, Http11, meth~) catch {
    @h1.ParseError(detail~, ..) => raise invalid_response(detail)
  }
  sent.val = true
  self.wire.write(head, limit)
  match (response.body, reader) {
    (Bytes(bytes), _) if !bodiless => self.wire.write(bytes, limit)
    (_, Some(reader)) => {
      let chunked = framing is Chunked
      let mut next = first
      while next is Some(bytes) {
        // A producer may return a large chunk; it goes out in slices, each
        // chunk-framed on its own, so no frame is built for the whole chunk.
        for offset = 0; offset < bytes.length(); {
          let end = offset + (bytes.length() - offset).min(io_bytes)
          let slice = bytes[offset:end]
          self.wire.write(
            if chunked {
              @h1.encode_chunk(slice)
            } else {
              slice.to_owned()
            },
            limit,
          )
          continue end
        }
        next = self.produce(reader)
      }
      if chunked {
        self.wire.write(@h1.encode_chunk(b""), limit)
      }
    }
    _ => ()
  }
  !close
}

///|
fn invalid_response(detail : String) -> @http.TransportError {
  @http.TransportError(kind=Invalid, phase=Head, detail~)
}

///|
/// The next piece of a streamed response, within the body deadline.
async fn Session::produce(
  self : Session,
  reader : &@http.BodyStream,
) -> Bytes? raise @http.TransportError {
  let limit = self.limits.body_timeout_ms
  within(
    self.wire.timer,
    limit,
    timeout(limit, Body, "the response body producer"),
    () => reader.read_some(),
  )
}

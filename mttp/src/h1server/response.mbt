// Writing the handler's response: framing from the body and the request
// method (`write_response_head` with `meth~` keeps HEAD, 204 and 304
// bodiless), a stream's first read before the head so a failing producer can
// still be answered with 500, and every write sliced to 64 KiB under the
// body deadline. A stream marked `@mttp.close_on_shutdown` is long-lived by
// design: its producer may stay silent for any time, since shutdown, not the
// body deadline, ends it. It is cut once `stopping` holds: it is no longer
// pulled, and the response ends where the stream had reached.

///|
/// Writes `response` to a request of `meth` and closes its body; `true` when
/// the connection may carry the next request. Sets `sent` once the head is
/// on its way, so that a failure before it can still be answered.
///
/// A stream cut at shutdown ends as its framing allows. A chunked body gets
/// its last chunk, so the client reads a complete response; every piece
/// pulled before the cut was written whole, so the body ends on a boundary
/// the producer chose (an event, for server-sent events). A body with a
/// Content-Length cannot end early, so the connection closes short of it,
/// and the client sees the response as incomplete rather than as a shorter
/// body; a body delimited by the close ends with it. The connection then
/// closes in every case, since the server is stopping.
async fn Session::write_response(
  self : Session,
  response : @mttp.Response,
  source : RequestBody,
  meth : @mttp.Method,
  version : @h1.Version,
  close : Bool,
  sent : Ref[Bool],
) -> Bool raise @mttp.TransportError {
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
    @mttp.Body::.. => raise invalid_response("unsupported response body")
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
  let cut = response.attributes.get(@mttp.close_on_shutdown) == Some(true)
  let stopped = Ref(false)
  let first = match reader {
    Some(reader) => {
      let first = self.produce(reader, cut~, stopped~)
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
        next = self.produce(reader, cut~, stopped~)
      }
      if chunked {
        self.wire.write(@h1.encode_chunk(b""), limit)
      }
    }
    _ => ()
  }
  !close && !stopped.val
}

///|
fn invalid_response(detail : String) -> @mttp.TransportError {
  @mttp.TransportError(kind=Invalid, phase=Head, detail~)
}

///|
/// How often a pull of a stream marked `close_on_shutdown` asks `stopping`.
/// The caller's `stopping` is a predicate with no notification to wait on,
/// so the pull asks it on the clock; only such streams pay for it, and only
/// while a pull waits.
let shutdown_poll_ms : Int32 = 250

///|
/// The next piece of a streamed response. Without `cut`, within the body
/// deadline. With `cut`, the pull may wait for any time (an event stream
/// stays silent until it has an event; writes to the client keep their
/// deadline), and it gives `None` once `stopping` holds, before the pull or
/// while it waits (the pull is cancelled then), and `stopped` records it.
async fn Session::produce(
  self : Session,
  reader : &@mttp.BodyStream,
  cut~ : Bool,
  stopped~ : Ref[Bool],
) -> Bytes? raise @mttp.TransportError {
  if !cut {
    let limit = self.limits.body_timeout_ms
    let expired = timeout(limit, Body, "the response body producer")
    return within(self.wire.timer, limit, expired, () => reader.read_some())
  }
  if (self.stopping)() {
    stopped.val = true
    return None
  }
  let mut next = None
  self.coordination.supervise(primary=() => next = reader.read_some(), monitor=() => {
    while !(self.stopping)() {
      self.clock.sleep(shutdown_poll_ms)
    }
    stopped.val = true
    // Cancels the pull; never leaves `produce`.
    raise @mttp.TransportError(
      kind=Closed,
      phase=Body,
      detail="the server is shutting down",
    )
  }) catch {
    error => if stopped.val { return None } else { raise error }
  }
  next
}

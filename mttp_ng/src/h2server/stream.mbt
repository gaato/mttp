// One request stream: its request built from the header block, its body
// read from the stream's buffer, its handler run and its response written.

///|
/// Response fields HTTP/2 forbids (RFC 9113, section 8.2.2).
let connection_fields : Array[String] = [
  "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade",
]

///|
/// A request body read from its stream's buffer. Each piece the handler
/// takes opens the stream's window by as much, and each wait is bounded by
/// `body_timeout_ms`.
priv struct RequestBody {
  served : Served
  stream : ServerStream
  mut done : Bool
}

///|
impl @mttp_core.BodyStream for RequestBody with fn read_some(self) {
  let served = self.served
  let stream = self.stream
  while !self.done {
    if stream.failure is Some(error) {
      raise error
    }
    if stream.body.length() > 0 {
      let bytes = stream.body.remove(0)
      served.session.consume_stream(stream.id, bytes.length())
      served.wake()
      return Some(bytes)
    }
    if stream.ended {
      self.done = true
      return None
    }
    if stream.closed is Some(_) || served.dead {
      raise @mttp_core.TransportError(
        kind=Network,
        phase=Body,
        detail="the client reset the stream before its body ended",
      )
    }
    let ms = served.limits.body_timeout_ms
    if !served.wait(ms) {
      let error = @mttp_core.TransportError(
        kind=Timeout(ms~),
        phase=Body,
        detail="no request body bytes for \{ms} ms",
      )
      stream.failure = Some(error)
      raise error
    }
  }
  None
}

///|
impl @mttp_core.BodyStream for RequestBody with fn close(self) {
  self.done = true
}

///|
/// The next piece of a response body: `Some(None)` at its end, `None` when
/// it failed or, with `wait`, took longer than `body_timeout_ms`. An event
/// stream (`close_on_shutdown`) waits for its next event for any time.
async fn Context::next_piece(
  self : Context,
  source : &@mttp_core.BodyStream,
  wait~ : Bool,
) -> Bytes?? {
  if !wait {
    return Some(source.read_some()) catch { _ => None }
  }
  let mut piece : Bytes?? = None
  ignore(
    self.served.timer.within(self.served.limits.body_timeout_ms, () => {
      piece = Some(source.read_some()) catch { _ => None }
    }),
  )
  piece
}

///|
/// The status a request body failure is answered with, as h1server has it.
fn body_status(error : @mttp_core.TransportError) -> Int32 {
  match error {
    @mttp_core.TransportError(kind=TooLarge(..), ..) => 413
    @mttp_core.TransportError(kind=Timeout(..), ..) => 408
    _ => 400
  }
}

///|
/// The request in `fields`, or the status to answer a malformed one with.
fn Context::request(
  self : Context,
  stream : ServerStream,
  fields : Array[(String, String)],
) -> Result[@mttp_core.Request, Int32] {
  let mut meth = None
  let mut authority = None
  let mut path = None
  let mut headers = @mttp_core.Headers::empty()
  // nghttp2 refused misplaced, repeated or unknown pseudo fields and
  // connection-specific ones (RFC 9113, section 8.3.1).
  for field in fields {
    match field {
      (":method", value) => meth = Some(value)
      (":authority", value) => authority = Some(value)
      (":path", value) => path = Some(value)
      (":scheme", _) => ()
      (name, value) => headers = headers.add(name, value)
    }
  }
  guard meth is Some(meth) && path is Some(path) else { return Err(400) }
  let authority = match authority {
    Some(authority) => authority
    None => headers.get("host").unwrap_or("localhost")
  }
  let length = match headers.get("content-length") {
    Some(text) => @string.parse_int64(text) catch { _ => return Err(400) }
    None => -1L
  }
  if length > self.served.limits.max_body_bytes.to_int64() {
    return Err(413)
  }
  let body : @mttp_core.Body = if stream.ended && stream.body.is_empty() {
    Empty
  } else {
    Stream(
      @mttp_core.StreamBody::new(
        RequestBody::{ served: self.served, stream, done: false, },
        length?=if length >= 0L { Some(length) } else { None },
      ),
    )
  }
  let mut attributes = @mttp_core.Attributes::empty().put(
    @mttp_core.protocol, "h2",
  )
  if self.peer is Some(peer) {
    attributes = attributes.put(@mttp_core.remote_addr, peer)
  }
  if @mttp_core.connection_scheme_of(self.scheme) is Some(scheme) {
    attributes = attributes.put(@mttp_core.connection_scheme, scheme)
  }
  if self.background is Some(schedule) {
    attributes = attributes.put(@mttp_core.background, schedule)
  }
  Ok({
    ..@mttp_core.Request::new(
      @mttp_core.Method::parse(meth),
      "\{self.scheme}://\{authority}\{path}",
    ),
    headers,
    body,
    attributes,
  })
}

///|
/// Runs the handler of one stream and writes its response.
async fn Context::run(
  self : Context,
  stream : ServerStream,
  fields : Array[(String, String)],
) -> Unit {
  let request = match self.request(stream, fields) {
    Ok(request) => request
    Err(status) => {
      self.respond(stream, @mttp_core.Response::new(status), head=false)
      return
    }
  }
  defer (if request.body is Stream(body) { body.close() })
  let limits = self.served.limits
  let response = match limits.handler_timeout_ms {
    None => (self.handler)(request)
    Some(ms) => {
      let mut response = None
      ignore(
        self.served.timer.within(ms, () => {
          response = Some((self.handler)(request))
        }),
      )
      match response {
        Some(response) => response
        None => {
          (self.on_error)(
            @mttp_core.TransportError(
              kind=Timeout(ms~),
              phase=Unknown,
              detail="the handler took longer than \{ms} ms",
            ),
          )
          @mttp_core.Response::new(504)
        }
      }
    }
  }
  // A body the handler could not read is answered with its own status,
  // even when the handler caught the failure and returned a response.
  let response = match stream.failure {
    Some(error) => {
      response.close()
      (self.on_error)(error)
      @mttp_core.Response::new(body_status(error))
    }
    None => response
  }
  self.respond(stream, response, head=request.meth is Head)
}

///|
/// Writes `response` on `stream`: its head, then its body through the
/// stream's queue, as fast as the client's window and the writer take it.
async fn Context::respond(
  self : Context,
  stream : ServerStream,
  response : @mttp_core.Response,
  head~ : Bool,
) -> Unit {
  let served = self.served
  let session = served.session
  defer response.close()
  let response = if response.status == 101 || response.status < 200 {
    // No upgrades in HTTP/2, and an interim response is not a final one.
    response.close()
    @mttp_core.Response::new(500)
  } else {
    response
  }
  let fields = [(":status", response.status.to_string())]
  for field in response.headers.iter() {
    let (name, value) = field
    let name = name.to_lower()
    if !connection_fields.contains(name) {
      fields.push((name, value))
    }
  }
  if self.auto_date && !response.headers.contains("date") {
    fields.push(
      ("date", @mttp_core.format_http_date(served.clock.now_unix_ms())),
    )
  }
  let bodiless = head || response.status == 204 || response.status == 304
  let body : Bytes? = match response.body {
    _ if bodiless => None
    Empty => None
    Bytes(bytes) => if bytes.length() == 0 { None } else { Some(bytes) }
    Stream(_) => Some(b"")
    @mttp_core.Body::.. => None
  }
  session.submit_response(stream.id, fields, body=body is Some(_)) catch {
    _ => return
  }
  served.wake()
  match (response.body, body) {
    (Bytes(bytes), Some(_)) =>
      session.push(stream.id, bytes, end=true) catch {
        _ => ()
      }
    (Stream(cell), Some(_)) => {
      let source = cell.take() catch { _ => return }
      defer source.close()
      let idle = response.attributes.get(@mttp_core.close_on_shutdown) ==
        Some(true)
      while true {
        // Room in the queue first, so a slow client holds back the body.
        while session.queued(stream.id).unwrap_or(0) >= QUEUE_BYTES {
          if stream.closed is Some(_) || served.dead {
            return
          }
          if !served.wait(served.limits.body_timeout_ms) {
            session.reset(stream.id, Cancel) catch {
              _ => ()
            }
            served.wake()
            return
          }
        }
        if stream.closed is Some(_) || served.dead {
          return
        }
        guard self.next_piece(source, wait=!idle) is Some(piece) else {
          session.reset(stream.id, InternalError) catch {
            _ => ()
          }
          served.wake()
          return
        }
        match piece {
          Some(bytes) =>
            session.push(stream.id, bytes, end=false) catch {
              _ => return
            }
          None => {
            session.push(stream.id, b"", end=true) catch {
              _ => ()
            }
            break
          }
        }
        served.wake()
      }
    }
    _ => ()
  }
  // The response is complete while the client still sends: once its last
  // frame went out (a reset drops what is still queued), the client is told
  // to stop, without an error (RFC 9113, section 8.1).
  served.wake()
  while !stream.ended &&
        stream.closed is None &&
        !stream.sent_end &&
        !served.dead {
    if !served.wait(served.limits.body_timeout_ms) {
      break
    }
  }
  if !stream.ended && stream.closed is None {
    session.reset(stream.id, NoError) catch {
      _ => ()
    }
  }
  served.wake()
}

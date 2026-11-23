// One request stream of an HTTP/2 or HTTP/3 server, the same for both: its
// request built from the header block, its body read from the stream's
// buffer, its handler run and its response written through the stream's
// queue. h2server and h3server keep only what their protocols do
// differently, behind `ServerConn`.
//
// The two servers began as copies of each other, and fixes reached one and
// not the other (a response body read without its timeout on HTTP/3; a lost
// wake-up and a body deadline reset by unrelated traffic on both). This file
// is the one copy.

///|
/// Response fields HTTP/2 and HTTP/3 forbid (RFC 9113, section 8.2.2;
/// RFC 9114, section 4.2).
let response_connection_fields : Array[String] = [
  "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade",
]

///|
/// Where one request stream stands, as its connection's events left it.
pub(all) struct ServerStream {
  /// The stream identifier (HTTP/2's fits in 31 bits).
  id : Int64
  /// Body bytes the handler has not read yet.
  body : Array[Bytes]
  priv mut received : Int64
  /// The client ended its half.
  mut ended : Bool
  /// The stream or its connection ended before the client's half did: a
  /// reset, or the connection gone.
  mut closed : Bool
  /// The response's last frame went out (HTTP/2 resets only after it).
  mut sent_end : Bool
  /// Why the request body cannot be read on (too large, too slow).
  mut failure : @mttp_core.TransportError?
}

///|
/// A stream whose request head arrived, ending its half with `ended`.
pub fn ServerStream::new(id : Int64, ended~ : Bool) -> ServerStream {
  {
    id,
    body: [],
    received: 0L,
    ended,
    closed: false,
    sent_end: false,
    failure: None,
  }
}

///|
/// Body bytes arrived: kept for the handler, or, past `limit`, dropped with
/// the stream failed as `TooLarge`. `false` when they were dropped, so the
/// connection acknowledges them at once rather than when read.
pub fn ServerStream::arrived(
  self : ServerStream,
  data : Bytes,
  limit : Int32,
) -> Bool {
  self.received += data.length().to_int64()
  if self.received <= limit.to_int64() {
    self.body.push(data)
    return true
  }
  if self.failure is None {
    self.failure = Some(
      @mttp_core.TransportError(
        kind=TooLarge(limit~),
        phase=Body,
        detail="the request body is larger than \{limit} bytes",
      ),
    )
  }
  false
}

///|
/// What a stream needs of its connection, which differs between HTTP/2 and
/// HTTP/3.
pub(open) trait ServerConn {
  /// Submits the response head on `stream`; `false` when the stream took
  /// none (it closed).
  fn submit_response(Self, Int64, Array[(String, String)], body~ : Bool) -> Bool
  /// Queues body bytes on `stream`; `false` when it takes no more.
  fn push(Self, Int64, Bytes, end~ : Bool) -> Bool
  /// Bytes of `stream`'s body not yet sent.
  fn queued(Self, Int64) -> Int32
  /// Acknowledges `len` body bytes of `stream` the handler took.
  fn consume(Self, Int64, Int32) -> Unit
  /// Ends `stream`, whose response failed midway.
  fn abort(Self, Int64) -> Unit
  /// Tells a client still sending its body, once the response is complete,
  /// that the server reads no more of it (RFC 9113, section 8.1; RFC 9114,
  /// section 4.1).
  async fn stop_reading(Self, ServerStream) -> Unit noraise
  /// Whether the connection can carry nothing more.
  fn gone(Self) -> Bool
  /// Has what the session must send now sent.
  async fn flush(Self) -> Unit noraise
}

///|
/// What every stream of a connection needs.
pub(all) struct ServerContext {
  conn : &ServerConn
  changes : Changes
  handler : @mttp_core.Handler
  limits : @h1server.ServerLimits
  /// `http` or `https`.
  scheme : String
  /// The ALPN identifier, `h2` or `h3`.
  protocol : String
  auto_date : Bool
  peer : String?
  clock : &@rt.Clock
  timer : &@rt.Timer
  on_error : (@mttp_core.TransportError) -> Unit
  background : ((async () -> Unit) -> Unit)?
}

///|
/// A request body read from its stream's buffer. One `body_timeout_ms`
/// covers it from the first read to its end, as h1server has it; the
/// deadline is a point in time, so traffic on other streams does not extend
/// it.
priv struct RequestBody {
  context : ServerContext
  stream : ServerStream
  mut deadline : Int64?
  mut done : Bool
}

///|
impl @mttp_core.BodyStream for RequestBody with fn read_some(self) {
  let context = self.context
  let stream = self.stream
  let ms = context.limits.body_timeout_ms
  let deadline = match self.deadline {
    Some(at) => at
    None => {
      let at = context.changes.deadline_in(ms)
      self.deadline = Some(at)
      at
    }
  }
  while !self.done {
    if stream.failure is Some(error) {
      raise error
    }
    if stream.body.length() > 0 {
      let bytes = stream.body.remove(0)
      context.conn.consume(stream.id, bytes.length())
      context.conn.flush()
      return Some(bytes)
    }
    if stream.ended {
      self.done = true
      return None
    }
    if stream.closed || context.conn.gone() {
      raise @mttp_core.TransportError(
        kind=Network,
        phase=Body,
        detail="the client reset the stream before its body ended",
      )
    }
    let arrived = context.changes.wait_until(
      () => {
        stream.body.length() > 0 ||
        stream.ended ||
        stream.closed ||
        stream.failure is Some(_) ||
        context.conn.gone()
      },
      deadline~,
    )
    if !arrived {
      let error = @mttp_core.TransportError(
        kind=Timeout(ms~),
        phase=Body,
        detail="the request body did not end within \{ms} ms",
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
/// nghttp2 and nghttp3 refused misplaced, repeated or unknown pseudo fields
/// and connection-specific ones.
fn ServerContext::request(
  self : ServerContext,
  stream : ServerStream,
  fields : Array[(String, String)],
) -> Result[@mttp_core.Request, Int32] {
  let mut meth = None
  let mut authority = None
  let mut path = None
  let mut headers = @mttp_core.Headers::empty()
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
  if length > self.limits.max_body_bytes.to_int64() {
    return Err(413)
  }
  let body : @mttp_core.Body = if stream.ended && stream.body.is_empty() {
    Empty
  } else {
    Stream(
      @mttp_core.StreamBody::new(
        RequestBody::{ context: self, stream, deadline: None, done: false, },
        length?=if length >= 0L { Some(length) } else { None },
      ),
    )
  }
  let mut attributes = @mttp_core.Attributes::empty().put(
    @mttp_core.protocol,
    self.protocol,
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
/// Runs the handler of `stream`, whose request head is `fields`, and writes
/// its response.
///
/// `limits` applies as it does to HTTP/1: a declared body over
/// `max_body_bytes` is answered 413 before the handler runs, a body read
/// that fails is answered with its own status (413, 408, 400) even when the
/// handler caught the failure, a handler over `handler_timeout_ms` is
/// answered 504, and `body_timeout_ms` bounds the request body from its
/// first read to its end, each wait for room to send the response, and each
/// read of a streamed response body unless the response sets
/// `close_on_shutdown`. A 101 or interim response becomes 500;
/// connection-specific fields are left out; `Date` is added unless
/// `auto_date` is false.
pub async fn ServerContext::serve(
  self : ServerContext,
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
  let response = match self.limits.handler_timeout_ms {
    None => (self.handler)(request)
    Some(ms) => {
      let mut response = None
      ignore(
        self.timer.within(ms, () => response = Some((self.handler)(request))),
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
/// The next piece of a response body: `Some(None)` at its end, `None` when
/// it failed or, with `wait`, took longer than `body_timeout_ms`.
async fn ServerContext::next_piece(
  self : ServerContext,
  source : &@mttp_core.BodyStream,
  wait~ : Bool,
) -> Bytes?? {
  if !wait {
    return Some(source.read_some()) catch { _ => None }
  }
  let mut piece : Bytes?? = None
  ignore(
    self.timer.within(self.limits.body_timeout_ms, () => {
      piece = Some(source.read_some()) catch { _ => None }
    }),
  )
  piece
}

///|
/// The size a stream's response queue may reach before the writer of its
/// body waits.
const QUEUE_BYTES : Int32 = 65536

///|
async fn ServerContext::respond(
  self : ServerContext,
  stream : ServerStream,
  response : @mttp_core.Response,
  head~ : Bool,
) -> Unit {
  let conn = self.conn
  defer response.close()
  let response = if response.status == 101 || response.status < 200 {
    // No upgrades in HTTP/2 or HTTP/3, and an interim response is not a
    // final one.
    response.close()
    @mttp_core.Response::new(500)
  } else {
    response
  }
  let fields = [(":status", response.status.to_string())]
  for field in response.headers.iter() {
    let (name, value) = field
    let name = name.to_lower()
    if !response_connection_fields.contains(name) {
      fields.push((name, value))
    }
  }
  if self.auto_date && !response.headers.contains("date") {
    fields.push(("date", @mttp_core.format_http_date(self.clock.now_unix_ms())))
  }
  let bodiless = head || response.status == 204 || response.status == 304
  let has_body = match response.body {
    _ if bodiless => false
    Empty => false
    Bytes(bytes) => bytes.length() > 0
    Stream(_) => true
    @mttp_core.Body::.. => false
  }
  if !conn.submit_response(stream.id, fields, body=has_body) {
    return
  }
  conn.flush()
  match response.body {
    Bytes(bytes) if has_body => ignore(conn.push(stream.id, bytes, end=true))
    Stream(cell) if has_body => {
      let source = cell.take() catch { _ => return }
      defer source.close()
      let idle = response.attributes.get(@mttp_core.close_on_shutdown) ==
        Some(true)
      while true {
        // Room in the queue first, so a slow client holds back the body;
        // each wait has its own `body_timeout_ms`.
        let room = self.changes.wait_until(
          () => {
            conn.queued(stream.id) < QUEUE_BYTES || stream.closed || conn.gone()
          },
          deadline=self.changes.deadline_in(self.limits.body_timeout_ms),
        )
        if stream.closed || conn.gone() {
          return
        }
        if !room {
          conn.abort(stream.id)
          conn.flush()
          return
        }
        guard self.next_piece(source, wait=!idle) is Some(piece) else {
          conn.abort(stream.id)
          conn.flush()
          return
        }
        match piece {
          Some(bytes) => if !conn.push(stream.id, bytes, end=false) { return }
          None => {
            ignore(conn.push(stream.id, b"", end=true))
            break
          }
        }
        conn.flush()
      }
    }
    _ => ()
  }
  conn.flush()
  if !stream.ended && !stream.closed {
    conn.stop_reading(stream)
  }
}

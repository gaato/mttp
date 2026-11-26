// One exchange of an HTTP/2 or HTTP/3 client, the same for both: the request
// body's ownership, the stream's request and upload, the response head and
// the response body, with the phases, deadlines and bounds of
// gaato/mttp_core's attempt. h2client and h3client keep their connections,
// pools and dials, and what their protocols say about a stream's end,
// behind `ClientConn`.
//
// The two clients began as copies, and a fix reached one and not the other
// (HTTP/3's left an untaken request body open when a send failed before
// its stream opened). This file is the one copy.

///|
/// How a stream ended, as its protocol's code says.
#derive(Eq, Debug)
pub(all) enum StreamEnd {
  /// Both halves ended, or the server ended the stream without an error
  /// (HTTP/2's NO_ERROR, HTTP/3's H3_NO_ERROR).
  Clean
  /// The server did not process the request (REFUSED_STREAM,
  /// H3_REQUEST_REJECTED).
  Refused(String)
  /// A reset with another code: a protocol error, or something else.
  Failed(protocol~ : Bool, String)
}

///|
/// Where one request stream stands, as its connection's events left it.
pub(all) struct ClientStream {
  id : Int64
  /// The final response: its status and fields.
  mut head : (Int32, @mttp_core.Headers)?
  /// Body bytes not yet taken by the reader, and how many.
  body : Array[Bytes]
  mut buffered : Int32
  /// The server ended its half.
  mut ended : Bool
  /// The stream closed, and how.
  mut closed : StreamEnd?
  /// Request bytes of this stream were serialized for sending: from here
  /// the request may have reached the server.
  mut headers_sent : Bool
  /// The whole request went out.
  mut sent_end : Bool
  /// The response head was larger than the limit.
  mut too_large : Bool
  /// The response head is not a valid response.
  mut malformed : String?
  /// The trailer section that followed the response body.
  mut trailers : @mttp_core.Headers
}

///|
/// A stream just opened.
pub fn ClientStream::new(id : Int64) -> ClientStream {
  {
    id,
    head: None,
    body: [],
    buffered: 0,
    ended: false,
    closed: None,
    headers_sent: false,
    sent_end: false,
    too_large: false,
    malformed: None,
    trailers: @mttp_core.Headers::empty(),
  }
}

///|
/// A response head arrived on the stream: kept when final, passed over
/// when interim, the stream marked malformed (`true` returned, so the
/// caller resets it) when it is not a valid response.
pub fn ClientStream::head_arrived(
  self : ClientStream,
  fields : Array[(String, String)],
) -> Bool {
  if self.head is Some(_) {
    // A section after the head is the trailers; nghttp2 and nghttp3 have
    // refused pseudo fields in it.
    self.trailers = @mttp_core.Headers::of(fields)
    return false
  }
  match response_head(fields) {
    Ok(None) => false
    Ok(Some(head)) => {
      self.head = Some(head)
      false
    }
    Err(detail) => {
      self.malformed = Some(detail)
      true
    }
  }
}

///|
/// Body bytes arrived on the stream.
pub fn ClientStream::data_arrived(self : ClientStream, data : Bytes) -> Unit {
  self.body.push(data)
  self.buffered += data.length()
}

///|
/// What an exchange needs of its connection, which differs between HTTP/2
/// and HTTP/3.
pub(open) trait ClientConn {
  /// Opens a stream for `fields`, with a body to follow when `body`. Raises
  /// `Refused` in phase Pool when the connection takes no new stream.
  fn open_stream(Self, Array[(String, String)], body~ : Bool) -> ClientStream raise @mttp_core.TransportError
  /// Queues body bytes; `false` when the stream takes no more.
  fn push(Self, ClientStream, Bytes, end~ : Bool) -> Bool
  /// Ends the request body after what was pushed with a trailer section;
  /// false as `push`.
  fn end_with_trailers(Self, ClientStream, Array[(String, String)]) -> Bool
  /// Bytes of the stream's request body not yet sent.
  fn queued(Self, ClientStream) -> Int32
  /// Gives the stream's window back by `len` bytes the reader took.
  fn consume(Self, ClientStream, Int32) -> Unit
  /// Ends the exchange's hold on the stream: one still open is reset.
  fn release(Self, ClientStream) -> Unit
  /// Writes what the connection has to send.
  async fn flush(Self) -> Unit raise @mttp_core.TransportError
  /// As `flush`, but nothing when a writer is at work, and no failure.
  async fn flush_if_idle(Self) -> Unit noraise
  /// Waits until `done` holds, reading the connection meanwhile when nobody
  /// else does; raises the connection's failure.
  async fn wait_until(Self, () -> Bool) -> Unit raise @mttp_core.TransportError
  /// Why the connection can carry nothing more.
  fn dead(Self) -> @mttp_core.TransportError?
  /// Whether the server's GOAWAY left the stream unprocessed.
  fn beyond_goaway(Self, ClientStream) -> Bool
}

///|
/// Reports a send's phase events (Backend rule 13), each at most once and
/// never after the send ended.
pub struct Phases {
  priv report : ((@mttp_core.PhaseEvent) -> Unit)?
  priv mut over : Bool
  priv mut written : Bool
  priv mut first_byte : Bool
}

///|
/// The events of `request`'s `on_phase` callback.
pub fn Phases::new(request : @mttp_core.Request) -> Phases {
  {
    report: request.attributes.get(@mttp_core.on_phase),
    over: false,
    written: false,
    first_byte: false,
  }
}

///|
/// No event after this: the send ended, or another engine took it.
pub fn Phases::end(self : Phases) -> Unit {
  self.over = true
}

///|
/// Reports `event`, unless the send ended, it was reported, or it is out of
/// order (`Written` after the first response byte).
pub fn Phases::emit(self : Phases, event : @mttp_core.PhaseEvent) -> Unit {
  if self.over {
    return
  }
  match event {
    Written => {
      if self.written || self.first_byte {
        return
      }
      self.written = true
    }
    FirstByte => {
      if self.first_byte {
        return
      }
      self.first_byte = true
    }
    _ => ()
  }
  if self.report is Some(report) {
    report(event)
  }
}

///|
/// A request's body, owned by the send from its start (Backend rule 3). A
/// stream body stays untaken until the send knows which engine writes it;
/// `finish`, deferred at the start, closes it on every exit: the taken
/// stream, or the untaken body, unless the request was handed to another
/// backend whole.
pub struct RequestSource {
  priv request : @mttp_core.Request
  priv mut handed : Bool
  priv mut taken : &@mttp_core.BodyStream?
}

///|
pub fn RequestSource::new(request : @mttp_core.Request) -> RequestSource {
  { request, handed: false, taken: None, }
}

///|
/// The request goes to another backend as it is, which takes its body.
pub fn RequestSource::hand_over(self : RequestSource) -> Unit {
  self.handed = true
}

///|
/// Takes the stream body, if the request has one.
pub fn RequestSource::take(
  self : RequestSource,
) -> &@mttp_core.BodyStream? raise @mttp_core.TransportError {
  match self.request.body {
    Stream(cell) => {
      let source = cell.take()
      self.taken = Some(source)
      Some(source)
    }
    _ => None
  }
}

///|
/// Closes what the send owns of the body; for a deferred call.
pub fn RequestSource::finish(self : RequestSource) -> Unit {
  match self.taken {
    Some(source) => source.close()
    None =>
      if !self.handed && self.request.body is Stream(cell) {
        cell.close()
      }
  }
}

///|
/// The bounds of an exchange: the response head (as reported in
/// `TooLarge`), the body ceiling of the engine, and the request body queue.
pub(all) struct ExchangeLimits {
  head_max : Int32
  max_body_bytes : Int32?
  queue_bytes : Int32
}

///|
/// The phase a stream has reached: Pool until its first bytes went out
/// (nothing of the request reached the server), Write until the whole
/// request did, Head until the response head arrived.
fn phase_of(stream : ClientStream) -> @mttp_core.Phase {
  if stream.head is Some(_) {
    Body
  } else if stream.sent_end {
    Head
  } else if stream.headers_sent {
    Write
  } else {
    Pool
  }
}

///|
/// Why `stream` ended without what was waited for, in `phase`.
fn failure(
  conn : &ClientConn,
  stream : ClientStream,
  phase : @mttp_core.Phase,
  limits : ExchangeLimits,
) -> @mttp_core.TransportError {
  if stream.too_large {
    let limit = limits.head_max
    return @mttp_core.TransportError(
      kind=TooLarge(limit~),
      phase=Head,
      detail="the response head is larger than \{limit} bytes",
    )
  }
  if stream.malformed is Some(detail) {
    return @mttp_core.TransportError(kind=Protocol, phase=Head, detail~)
  }
  // Nothing of the request went out: whatever happened, it is unsent.
  let phase = if stream.headers_sent { phase } else { Pool }
  if conn.beyond_goaway(stream) {
    return @mttp_core.TransportError(
      kind=Refused,
      phase~,
      detail="the server's GOAWAY left stream \{stream.id} unprocessed",
    )
  }
  match stream.closed {
    Some(Refused(detail)) =>
      @mttp_core.TransportError(kind=Refused, phase~, detail~)
    Some(Failed(protocol~, detail)) =>
      @mttp_core.TransportError(
        kind=if protocol { Protocol } else { Network },
        phase~,
        detail="the stream was reset: \{detail}",
      )
    Some(Clean) | None =>
      match conn.dead() {
        Some(error) => with_phase(error, phase)
        None =>
          @mttp_core.TransportError(
            kind=Network,
            phase~,
            detail="the stream ended without a response",
          )
      }
  }
}

///|
/// One exchange on `conn`: opens the stream, sends the request and its
/// body, and returns the response once its head has arrived, its body a
/// stream the caller reads to its end or closes. `source` and `first` are
/// the request body's stream and its first piece, read before anything
/// was sent (rule 3). A final response before the whole request body went
/// stops the upload; the stream is reset once the response ends, unless the
/// server already ended it. `protocol` is the ALPN identifier the response
/// records.
pub async fn exchange(
  conn : &ClientConn,
  coordination : &@rt.Coordination,
  fields : Array[(String, String)],
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
  timer : @attempt.AttemptTimer,
  phases : Phases,
  reused~ : Bool,
  source : &@mttp_core.BodyStream?,
  first : Bytes?,
  limits : ExchangeLimits,
  protocol~ : String,
) -> @mttp_core.Response raise @mttp_core.TransportError {
  // A stream that ended at once may still have trailers to send.
  let empty_with_trailers = first is None &&
    source is Some(s) &&
    s.trailers().length() > 0
  let has_body = match (first, source) {
    (Some(bytes), None) => bytes.length() > 0
    (Some(_), Some(_)) => true
    _ => empty_with_trailers
  }
  let stream = conn.open_stream(fields, body=has_body)
  phases.emit(Pooled(reused~))
  // Whatever ends the send before a response is returned ends its stream.
  let mut returned = false
  defer (if !returned { conn.release(stream) })
  match (first, source) {
    (Some(bytes), None) if has_body =>
      ignore(conn.push(stream, bytes, end=true))
    (Some(piece), Some(_)) => ignore(conn.push(stream, piece, end=false))
    (None, Some(s)) if empty_with_trailers => ignore(end_body(conn, stream, s))
    _ => ()
  }
  let upload_done = Ref(!(source is Some(_) && first is Some(_)))
  let outcome : Ref[@mttp_core.Response?] = Ref(None)
  coordination.supervise(
    primary=() => {
      timer.run(Write, () => conn.flush())
      while true {
        if stream.sent_end {
          phases.emit(Written)
        }
        if stream.head is Some((status, headers)) {
          phases.emit(FirstByte)
          outcome.val = Some(
            response(
              conn, stream, status, headers, request, options, timer, limits, protocol,
            ),
          )
          return
        }
        if stream.closed is Some(_) ||
          stream.too_large ||
          stream.malformed is Some(_) {
          raise failure(conn, stream, phase_of(stream), limits)
        }
        let phase = phase_of(stream)
        let sent = stream.sent_end
        timer.run(phase, () => {
          conn.wait_until(() => {
            stream.head is Some(_) ||
            stream.closed is Some(_) ||
            stream.too_large ||
            stream.malformed is Some(_) ||
            stream.sent_end != sent
          }) catch {
            @mttp_core.TransportError(..) =>
              raise failure(conn, stream, phase, limits)
          }
        })
      }
    },
    monitor=() => {
      guard source is Some(source) else { return }
      while !upload_done.val {
        timer.run(Write, () => {
          conn.wait_until(() => {
            stream.head is Some(_) ||
            stream.closed is Some(_) ||
            conn.queued(stream) < limits.queue_bytes
          }) catch {
            @mttp_core.TransportError(..) =>
              raise failure(conn, stream, Write, limits)
          }
        })
        if stream.head is Some(_) || stream.closed is Some(_) {
          return
        }
        match timer.run(Write, () => source.read_some()) {
          Some(bytes) => if !conn.push(stream, bytes, end=false) { return }
          None => {
            if !end_body(conn, stream, source) {
              return
            }
            upload_done.val = true
          }
        }
        timer.run(Write, () => conn.flush())
      }
    },
  )
  guard outcome.val is Some(response) else {
    raise @mttp_core.TransportError(
      kind=Protocol,
      phase=Head,
      detail="the exchange ended without a response head",
    )
  }
  returned = true
  response
}

///|
/// Ends the request body after its last byte: with the source's trailers,
/// when it has some. Trailers that cannot be sent fail the upload, which
/// resets the stream, rather than end the request as whole.
fn end_body(
  conn : &ClientConn,
  stream : ClientStream,
  source : &@mttp_core.BodyStream,
) -> Bool raise @mttp_core.TransportError {
  let trailers = source.trailers()
  if trailers.length() == 0 {
    return conn.push(stream, b"", end=true)
  }
  match trailer_fields(trailers) {
    Ok(fields) => conn.end_with_trailers(stream, fields)
    Err(detail) =>
      raise @mttp_core.TransportError(
        kind=Invalid,
        phase=Write,
        detail="the request's trailers cannot be sent: \{detail}",
      )
  }
}

///|
/// The response whose head has arrived on `stream`.
fn response(
  conn : &ClientConn,
  stream : ClientStream,
  status : Int32,
  headers : @mttp_core.Headers,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
  timer : @attempt.AttemptTimer,
  limits : ExchangeLimits,
  protocol : String,
) -> @mttp_core.Response {
  let attributes = @mttp_core.Attributes::empty().put(
    @mttp_core.protocol, protocol,
  )
  let bodiless = request.meth is Head || status == 204 || status == 304
  if bodiless || (stream.ended && stream.buffered == 0) {
    conn.release(stream)
    // Trailers that came with the head, and no body between.
    let body = if stream.trailers.length() > 0 {
      @mttp_core.Body::with_trailers(b"", trailers=stream.trailers)
    } else {
      Empty
    }
    return { ..@mttp_core.Response::new(status, headers~, body~), attributes, }
  }
  // A declared length bounds the body before any of it is read.
  let declared = match headers.get("content-length") {
    Some(text) => @string.parse_int64(text) catch { _ => -1L }
    None => -1L
  }
  let body = ResponseBody::{
    conn,
    stream,
    timer: timer.for_body(options.body),
    budget: @attempt.BodyBudget::new(
      @attempt.body_limit(options.body, ceiling?=limits.max_body_bytes),
    ),
    declared: if declared >= 0L {
      Some(declared)
    } else {
      None
    },
    finished: false,
    complete: false,
  }
  {
    ..@mttp_core.Response::new(
      status,
      headers~,
      body=Stream(@mttp_core.StreamBody::new(body)),
    ),
    attributes,
  }
}

///|
/// A response body read from its stream's buffer. Each piece the reader
/// takes gives the stream's window back by as much.
priv struct ResponseBody {
  conn : &ClientConn
  stream : ClientStream
  timer : @attempt.AttemptTimer
  budget : @attempt.BodyBudget
  declared : Int64?
  mut finished : Bool
  /// The body was read to its end.
  mut complete : Bool
}

///|
impl @mttp_core.BodyStream for ResponseBody with fn read_some(self) {
  if self.finished {
    return None
  }
  errdefer self.close_stream()
  self.budget.check_declared(self.declared)
  let conn = self.conn
  let stream = self.stream
  self.timer.run(Body, () => {
    conn.wait_until(() => {
      stream.body.length() > 0 || stream.ended || stream.closed is Some(_)
    }) catch {
      @mttp_core.TransportError(..) as error => raise with_phase(error, Body)
    }
  })
  if stream.body.length() > 0 {
    let bytes = stream.body.remove(0)
    stream.buffered -= bytes.length()
    self.budget.admit(bytes.length())
    conn.consume(stream, bytes.length())
    conn.flush_if_idle()
    return Some(bytes)
  }
  // A reset without an error after the response is how a server ends a
  // stream whose request it will not read on (RFC 9113, section 8.1;
  // RFC 9114, section 4.1); some send it before the frame that ends the
  // body, so it ends the body too, unless a declared length says bytes
  // are missing.
  let complete = stream.ended ||
    (
      stream.closed == Some(Clean) &&
      (self.declared is None || self.declared == Some(self.budget.count()))
    )
  if complete {
    self.complete = true
    self.close_stream()
    return None
  }
  let (protocol, detail) = match stream.closed {
    Some(Failed(protocol~, detail)) => (protocol, detail)
    Some(Refused(detail)) => (false, detail)
    _ => (false, "the stream ended early")
  }
  raise @mttp_core.TransportError(
    kind=if protocol { Protocol } else { Network },
    phase=Body,
    detail="the stream was reset before its body ended: \{detail}",
  )
}

///|
fn ResponseBody::close_stream(self : ResponseBody) -> Unit {
  self.finished = true
  self.conn.release(self.stream)
}

///|
impl @mttp_core.BodyStream for ResponseBody with fn trailers(self) {
  if self.complete {
    self.stream.trailers
  } else {
    @mttp_core.Headers::empty()
  }
}

///|
impl @mttp_core.BodyStream for ResponseBody with fn close(self) {
  if !self.finished {
    self.close_stream()
  }
}

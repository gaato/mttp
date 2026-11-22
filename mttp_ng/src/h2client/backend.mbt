// H2Backend: gaato/mttp_core's Backend over HTTP/2 connections of our own,
// one per origin, each carrying every request to that origin at once.

///|
/// An HTTP/2 client over the `rt` ports: one connection per origin with
/// every request to it multiplexed, TLS with ALPN of its own
/// (`@tls.ClientTls`), and SendOptions' deadlines and bounds kept as
/// gaato/mttp_core's HTTP/1 client keeps them (`@attempt`). It implements
/// `@mttp_core.Backend`, so it moves raw bytes: no redirects, retries,
/// cookies or content decoding.
///
/// `https` URLs go over TLS with ALPN `h2`; `http` URLs go over cleartext
/// HTTP/2 with prior knowledge (h2c) only when built with `h2c=true`, for
/// servers known to speak it, and are refused otherwise. A server that does
/// not choose `h2` fails the send in phase Dial (`Connect`); the root
/// package's `backend()` falls back to HTTP/1.1 instead.
///
/// The engine never sends a request twice. A stream the server refused
/// (REFUSED_STREAM, or above its GOAWAY's last stream) fails with `Refused`,
/// which `@mttp_core.is_unsent` counts, so the Client's retries may send it
/// again whatever its method.
pub struct H2Backend {
  priv dialer : &@rt.Dialer
  priv tls : @tls.ClientTls
  priv clock : &@rt.Clock
  priv timer : &@rt.Timer
  priv coordination : &@rt.Coordination
  priv config : @h1client.ClientConfig
  priv settings : @h2.H2Settings
  priv h2c : Bool
  priv max_connection_age_ms : Int32?
  priv origins : Map[String, Origin]
  /// Rung and replaced when a dial ends, for sends waiting on it.
  priv mut changed : &@rt.Signal
  priv mut closed : Bool
}

///|
/// The connections to one origin: usually one, and older ones that take no
/// new stream until their last stream ends.
priv struct Origin {
  conns : Array[Connection]
  mut dialing : Bool
}

///|
/// A backend over `dialer` (TCP only: TLS is this backend's own, under
/// `trust`) and the given ports. The defaults are gaato/mttp's runtime and
/// `@conn.TcpDialer::new()`. `config` gives the phase limits, the body
/// ceiling, the response head bound (as SETTINGS_MAX_HEADER_LIST_SIZE) and
/// how long a connection may stay idle (`idle_max_ms`); its proxy and its
/// connection caps do not apply. `max_connection_age_ms` retires a
/// connection at that age: it takes no new stream, and closes when its last
/// one ends. `h2c` lets `http` URLs speak HTTP/2 with prior knowledge.
///
/// `ClientTls::new` refuses no trust this backend accepts, so `new` does
/// not raise; an unreadable PEM file fails each send in phase Dial.
pub fn H2Backend::new(
  dialer? : &@rt.Dialer,
  trust~ : @trust.Trust = System,
  config~ : @h1client.ClientConfig = @h1client.ClientConfig::default(),
  h2c~ : Bool = false,
  max_connection_age_ms? : Int32,
  clock? : &@rt.Clock,
  timer? : &@rt.Timer,
  coordination? : &@rt.Coordination,
) -> H2Backend {
  let clock : &@rt.Clock = match clock {
    Some(clock) => clock
    None => @runtime.AsyncClock::new()
  }
  let timer : &@rt.Timer = match timer {
    Some(timer) => timer
    None => @runtime.ClockTimer::new(clock~)
  }
  let coordination : &@rt.Coordination = match coordination {
    Some(coordination) => coordination
    None => @runtime.RuntimeCoordination::new()
  }
  let dialer : &@rt.Dialer = match dialer {
    Some(dialer) => dialer
    None => @conn.TcpDialer::new()
  }
  // The ALPN list is fixed and valid, and every Trust case is known.
  let tls = @tls.ClientTls::new(trust~, alpn=["h2"]) catch {
    _ => abort("ClientTls::new refused a fixed configuration")
  }
  {
    dialer,
    tls,
    clock,
    timer,
    coordination,
    config,
    settings: {
      ..@h2.H2Settings::client(),
      max_header_list: config.head_limits.max_head_bytes,
    },
    h2c,
    max_connection_age_ms,
    origins: Map([]),
    changed: coordination.signal(),
    closed: false,
  }
}

///|
/// Connections open over all origins, busy or idle.
pub fn H2Backend::connections(self : H2Backend) -> Int32 {
  let mut n = 0
  for _, origin in self.origins {
    n += origin.conns.length()
  }
  n
}

///|
/// Closes every connection and refuses later sends with `Closed` in phase
/// Pool. Exchanges in flight fail with `Closed`; their bodies stay closable.
/// Idempotent.
pub fn H2Backend::close(self : H2Backend) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  for _, origin in self.origins {
    for connection in origin.conns {
      connection.close()
    }
  }
  self.origins.clear()
  self.notify()
}

///|
fn H2Backend::notify(self : H2Backend) -> Unit {
  let woken = self.changed
  self.changed = self.coordination.signal()
  woken.notify()
}

///|
fn closed_error() -> @mttp_core.TransportError {
  @mttp_core.TransportError(
    kind=Closed,
    phase=Pool,
    detail="the backend is closed",
  )
}

///|
/// Drops what the origin no longer needs: closed connections, and retired,
/// idle-expired or aged ones without streams.
fn H2Backend::sweep(self : H2Backend, origin : Origin) -> Unit {
  let now = self.clock.now_unix_ms()
  let keep = []
  for connection in origin.conns {
    if connection.closed {
      continue
    }
    if self.max_connection_age_ms is Some(age) &&
      now - connection.opened_at >= age.to_int64() {
      connection.retired = true
    }
    let idle_expired = connection.active == 0 &&
      connection.reserved == 0 &&
      now - connection.idle_since >= self.config.idle_max_ms.to_int64()
    if (connection.retired || connection.dead is Some(_) || idle_expired) &&
      connection.active == 0 &&
      connection.reserved == 0 {
      connection.close()
      continue
    }
    keep.push(connection)
  }
  origin.conns.clear()
  origin.conns.append(keep)
}

///|
/// A connection to `target`'s origin with room for one more stream, which
/// it reserves, and whether it was already open.
async fn H2Backend::connection(
  self : H2Backend,
  target : Target,
  timer : @attempt.AttemptTimer,
  phases : Phases,
) -> (Connection, Bool) raise @mttp_core.TransportError {
  let origin = match self.origins.get(target.origin) {
    Some(origin) => origin
    None => {
      let origin = { conns: [], dialing: false, }
      self.origins[target.origin] = origin
      origin
    }
  }
  while true {
    if self.closed {
      raise closed_error()
    }
    self.sweep(origin)
    let open = origin.conns.filter(c => c.usable())
    if open.last() is Some(connection) {
      // One that sat idle may have been closed by the server meanwhile:
      // what it already sent is read before a stream goes on it.
      if connection.active == 0 &&
        self.clock.now_unix_ms() - connection.idle_since >= 100L {
        connection.probe()
        if !connection.usable() {
          continue
        }
      }
      if connection.has_room() {
        connection.reserved += 1
        return (connection, true)
      }
      // Every stream the server allows is in use: wait for one to end,
      // reading the connection meanwhile.
      timer.run(Pool, () => {
        connection.wait_until(() => {
          connection.has_room() || !connection.usable()
        }) catch {
          @mttp_core.TransportError(..) => ()
        }
      })
      continue
    }
    if origin.dialing {
      let signal = self.changed
      timer.run(Pool, () => signal.wait())
      continue
    }
    origin.dialing = true
    let connection = {
      defer {
        origin.dialing = false
        self.notify()
      }
      timer.run(Dial, () => self.dial(target, phases))
    }
    if self.closed {
      connection.close()
      raise closed_error()
    }
    origin.conns.push(connection)
    connection.reserved += 1
    return (connection, false)
  }
  abort("unreachable")
}

///|
/// Opens a connection to `target`: TCP through the dialer, then TLS with
/// ALPN for `https`, or cleartext HTTP/2 for `http` with `h2c`.
async fn H2Backend::dial(
  self : H2Backend,
  target : Target,
  phases : Phases,
) -> Connection raise @mttp_core.TransportError {
  let tcp = self.dialer.connect(host=target.host, port=target.port)
  let mut owned = true
  defer (if owned { tcp.close() })
  phases.emit(Dialed(addr=target.address))
  let conn : &@rt.Conn = if target.secure {
    let tls : @tls.TlsConn = self.tls.connect(
      tcp,
      host=target.host,
      coordination=self.coordination,
    )
    owned = false
    phases.emit(TlsDone)
    if tls.alpn() != Some("h2") {
      tls.close()
      raise @mttp_core.TransportError(
        kind=Connect,
        phase=Dial,
        detail="the server did not choose h2 by ALPN (\{tls.alpn().unwrap_or("none")})",
      )
    }
    (tls : &@rt.Conn)
  } else {
    owned = false
    tcp
  }
  let session = @h2.H2Session::client(settings=self.settings) catch {
    error => {
      conn.close()
      raise @mttp_core.TransportError(
        kind=Connect,
        phase=Dial,
        detail=error.to_string(),
      )
    }
  }
  Connection::new(conn, session, self.coordination, self.timer, self.clock)
}

///|
/// Reports a send's phase events (Backend rule 13), each at most once and
/// never after the send ended.
priv struct Phases {
  report : ((@mttp_core.PhaseEvent) -> Unit)?
  mut over : Bool
  mut written : Bool
  mut first_byte : Bool
}

///|
fn Phases::emit(self : Phases, event : @mttp_core.PhaseEvent) -> Unit {
  if self.over {
    return
  }
  match event {
    Written => {
      // Out of order after an early response: left out.
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
/// `H2Backend::send`.
pub impl @mttp_core.Backend for H2Backend with fn send(self, request, options) {
  self.send(request, options)
}

///|
/// `H2Backend::close`.
pub impl @mttp_core.Backend for H2Backend with fn close(self) {
  self.close()
}

///|
/// One exchange on a stream of the origin's connection: the response once
/// its head has arrived, its body a stream the caller reads to its end or
/// closes. See `H2Backend` and CONTRACT.md (Backend; SendOptions and
/// BodyTiming).
///
/// The request is validated before any I/O, and so are `options`. A stream
/// body is taken and its first piece read before anything is written, and
/// closed on every exit. CONNECT and protocol upgrades are refused with
/// `Invalid`: HTTP/2 has neither in this engine. A final response before the
/// whole request body was sent stops the upload; the stream is reset once
/// the response ends, unless the server already ended it.
pub async fn H2Backend::send(
  self : H2Backend,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
) -> @mttp_core.Response raise @mttp_core.TransportError {
  // Taken first, so that every exit below closes it.
  let source = match request.body {
    Stream(cell) => Some(cell.take())
    _ => None
  }
  defer (if source is Some(source) { source.close() })
  if self.closed {
    raise closed_error()
  }
  options.validate()
  match options.body {
    Exchange(..) | Stream(..) => ()
    @mttp_core.BodyTiming::.. =>
      raise invalid("a BodyTiming this backend does not know")
  }
  if self.config.max_body_bytes is Some(n) && n < 0 {
    raise invalid("negative body byte ceiling")
  }
  let target = target(request)
  if request.meth is Connect {
    raise invalid("CONNECT is not sent by this backend")
  }
  if request.headers.get("upgrade") is Some(_) {
    raise invalid("protocol upgrades do not exist in HTTP/2")
  }
  if !target.secure && !self.h2c {
    raise invalid(
      "an http URL: this backend speaks HTTP/2 over TLS, or over cleartext only with h2c=true",
    )
  }
  let limits : @attempt.PhaseLimits = {
    pool: self.config.pool_timeout_ms,
    connect: self.config.connect_timeout_ms,
    write: self.config.write_timeout_ms,
    read: self.config.read_timeout_ms,
  }
  let timer = @attempt.AttemptTimer::new(
    self.clock,
    self.timer,
    options.timeout_ms,
    limits~,
  )
  // The request body's first piece, read before anything is sent (rule 3).
  let first = match source {
    Some(source) => timer.run(Pool, () => source.read_some())
    None => request.body.as_bytes()
  }
  let fields = request_fields(request, target)
  let phases = {
    report: request.attributes.get(@mttp_core.on_phase),
    over: false,
    written: false,
    first_byte: false,
  }
  defer {
    phases.over = true
  }
  let (connection, reused) = self.connection(target, timer, phases)
  connection.reserved -= 1
  let has_body = match (first, source) {
    (Some(bytes), None) => bytes.length() > 0
    (Some(_), Some(_)) => true
    _ => false
  }
  let id = connection.session.submit_request(fields, body=has_body) catch {
    error => {
      connection.retired = true
      connection.notify()
      raise @mttp_core.TransportError(
        kind=Refused,
        phase=Pool,
        detail="the connection took no new stream: \{error}",
      )
    }
  }
  let stream = Stream::new(id)
  connection.streams[id] = stream
  connection.active += 1
  phases.emit(Pooled(reused~))
  // Whatever ends the send before a response is returned ends its stream.
  let mut returned = false
  defer (if !returned { connection.release(stream) })
  match (first, source) {
    (Some(bytes), None) if has_body =>
      connection.session.push(id, bytes, end=true) catch {
        _ => ()
      }
    (Some(piece), Some(_)) =>
      connection.session.push(id, piece, end=false) catch {
        _ => ()
      }
    _ => ()
  }
  let upload_done = Ref(!(source is Some(_) && first is Some(_)))
  let outcome : Ref[@mttp_core.Response?] = Ref(None)
  self.coordination.supervise(
    primary=() => {
      timer.run(Write, () => connection.flush())
      while true {
        if stream.sent_end {
          phases.emit(Written)
        }
        if stream.head is Some((status, headers)) {
          phases.emit(FirstByte)
          outcome.val = Some(
            self.response(
              connection, stream, status, headers, request, options, timer,
            ),
          )
          return
        }
        if stream.closed is Some(_) ||
          stream.too_large ||
          stream.malformed is Some(_) {
          raise self.stream_failure(connection, stream, phase_of(stream))
        }
        let phase = phase_of(stream)
        let sent = stream.sent_end
        timer.run(phase, () => {
          connection.wait_until(() => {
            stream.head is Some(_) ||
            stream.closed is Some(_) ||
            stream.too_large ||
            stream.malformed is Some(_) ||
            stream.sent_end != sent
          }) catch {
            @mttp_core.TransportError(..) =>
              raise self.stream_failure(connection, stream, phase)
          }
        })
      }
    },
    monitor=() => {
      guard source is Some(source) else { return }
      while !upload_done.val {
        timer.run(Write, () => {
          connection.wait_until(() => {
            stream.head is Some(_) ||
            stream.closed is Some(_) ||
            connection.session.queued(id).unwrap_or(0) < QUEUE_BYTES
          }) catch {
            @mttp_core.TransportError(..) =>
              raise self.stream_failure(connection, stream, Write)
          }
        })
        if stream.head is Some(_) || stream.closed is Some(_) {
          return
        }
        match timer.run(Write, () => source.read_some()) {
          Some(bytes) =>
            connection.session.push(id, bytes, end=false) catch {
              _ => return
            }
          None => {
            connection.session.push(id, b"", end=true) catch {
              _ => return
            }
            upload_done.val = true
          }
        }
        timer.run(Write, () => connection.flush())
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
/// The phase a stream has reached: Pool until its HEADERS went out (nothing
/// of the request reached the server), Write until the whole request did,
/// Head until the response head arrived.
fn phase_of(stream : Stream) -> @mttp_core.Phase {
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
fn H2Backend::stream_failure(
  self : H2Backend,
  connection : Connection,
  stream : Stream,
  phase : @mttp_core.Phase,
) -> @mttp_core.TransportError {
  if stream.too_large {
    let limit = self.config.head_limits.max_head_bytes
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
  if connection.goaway is Some(last) && stream.id > last {
    return @mttp_core.TransportError(
      kind=Refused,
      phase~,
      detail="the server's GOAWAY named stream \{last} as its last; stream \{stream.id} was not processed",
    )
  }
  match stream.closed {
    Some(RefusedStream) =>
      @mttp_core.TransportError(
        kind=Refused,
        phase~,
        detail="the server refused the stream (REFUSED_STREAM)",
      )
    Some(code) =>
      @mttp_core.TransportError(
        kind=if code == ProtocolError { Protocol } else { Network },
        phase~,
        detail="the stream was reset: \{code.to_repr()}",
      )
    None =>
      match connection.dead {
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
/// The response whose head has arrived on `stream`.
fn H2Backend::response(
  self : H2Backend,
  connection : Connection,
  stream : Stream,
  status : Int32,
  headers : @mttp_core.Headers,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
  timer : @attempt.AttemptTimer,
) -> @mttp_core.Response {
  let attributes = @mttp_core.Attributes::empty().put(@mttp_core.protocol, "h2")
  let bodiless = request.meth is Head || status == 204 || status == 304
  if bodiless || (stream.ended && stream.buffered == 0) {
    connection.release(stream)
    return { ..@mttp_core.Response::new(status, headers~), attributes, }
  }
  // A declared length bounds the body before any of it is read.
  let declared = match headers.get("content-length") {
    Some(text) => @string.parse_int64(text) catch { _ => -1L }
    None => -1L
  }
  let body = H2Body::{
    connection,
    stream,
    timer: timer.for_body(options.body),
    budget: @attempt.BodyBudget::new(
      @attempt.body_limit(options.body, ceiling?=self.config.max_body_bytes),
    ),
    declared: if declared >= 0L {
      Some(declared)
    } else {
      None
    },
    finished: false,
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
/// takes opens the stream's window by as much.
priv struct H2Body {
  connection : Connection
  stream : Stream
  timer : @attempt.AttemptTimer
  budget : @attempt.BodyBudget
  declared : Int64?
  mut finished : Bool
}

///|
impl @mttp_core.BodyStream for H2Body with fn read_some(self) {
  if self.finished {
    return None
  }
  errdefer self.close_stream()
  self.budget.check_declared(self.declared)
  let connection = self.connection
  let stream = self.stream
  self.timer.run(Body, () => {
    connection.wait_until(() => {
      stream.body.length() > 0 || stream.ended || stream.closed is Some(_)
    }) catch {
      @mttp_core.TransportError(..) as error => raise with_phase(error, Body)
    }
  })
  if stream.body.length() > 0 {
    let bytes = stream.body.remove(0)
    stream.buffered -= bytes.length()
    self.budget.admit(bytes.length())
    connection.session.consume_stream(stream.id, bytes.length())
    connection.flush_if_idle()
    return Some(bytes)
  }
  // RST_STREAM(NO_ERROR) after the response is how a server ends a stream
  // whose request it will not read on (RFC 9113, section 8.1); some send it
  // before the DATA frame that ends the body, so it ends the body too,
  // unless a declared length says bytes are missing.
  let complete = stream.ended ||
    (
      stream.closed == Some(NoError) &&
      (self.declared is None || self.declared == Some(self.budget.count()))
    )
  if complete {
    self.close_stream()
    return None
  }
  let code = stream.closed.unwrap_or(InternalError)
  raise @mttp_core.TransportError(
    kind=if code == ProtocolError { Protocol } else { Network },
    phase=Body,
    detail="the stream was reset before its body ended: \{code.to_repr()}",
  )
}

///|
fn H2Body::close_stream(self : H2Body) -> Unit {
  self.finished = true
  self.connection.release(self.stream)
}

///|
impl @mttp_core.BodyStream for H2Body with fn close(self) {
  if !self.finished {
    self.close_stream()
  }
}

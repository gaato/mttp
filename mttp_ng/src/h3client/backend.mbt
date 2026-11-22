// H3Backend: gaato/mttp_core's Backend over QUIC connections of our own, one
// per origin, each carrying every request to that origin at once.

///|
/// How long a QUIC handshake may take before the origin counts as not
/// speaking HTTP/3 (`try_send` then declines, and TCP is used).
const HANDSHAKE_MS : Int32 = 1000

///|
/// How long an origin whose QUIC handshake failed is not tried again.
const BROKEN_MS : Int64 = 300000L

///|
/// At most this many origins are remembered as without HTTP/3.
const BROKEN_ORIGINS : Int32 = 256

///|
/// An HTTP/3 client: QUIC over UDP with TLS 1.3 (ngtcp2 with OpenSSL), one
/// connection per origin with every request to it on a stream of its own,
/// and SendOptions' deadlines and bounds kept as gaato/mttp_core's HTTP/1
/// client keeps them (`@attempt`). It implements `@mttp_core.Backend`, so it
/// moves raw bytes. Only `https` URLs; no proxies (QUIC does not go through
/// an HTTP proxy) and no 0-RTT.
///
/// `@mttp_ng.backend(http3=true)` puts it in front of `@h2client.H2Backend`:
/// an origin whose QUIC handshake does not finish in a second goes over TCP
/// for five minutes.
pub struct H3Backend {
  priv quic : @h3.ClientQuic?
  priv quic_error : String
  priv clock : &@rt.Clock
  priv timer : &@rt.Timer
  priv coordination : &@rt.Coordination
  priv config : @h1client.ClientConfig
  priv settings : @h3.H3Settings
  priv max_connection_age_ms : Int32?
  priv origins : Map[String, Origin]
  priv broken : Map[String, Int64]
  priv mut changed : &@rt.Signal
  priv mut closed : Bool
}

///|
priv struct Origin {
  conns : Array[Connection]
  mut dialing : Bool
}

///|
/// A backend under `trust`, with the phase limits, the body ceiling and the
/// response head bound of `config` (its proxy and caps do not apply), over
/// the given ports (gaato/mttp's runtime by default).
pub fn H3Backend::new(
  trust~ : @trust.Trust = System,
  config~ : @h1client.ClientConfig = @h1client.ClientConfig::default(),
  max_connection_age_ms? : Int32,
  clock? : &@rt.Clock,
  timer? : &@rt.Timer,
  coordination? : &@rt.Coordination,
) -> H3Backend {
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
  // An unreadable PEM file fails each send in phase Dial, as TLS's does.
  let (quic, quic_error) = (Some(@h3.ClientQuic::new(trust~)), "") catch {
    error => (None, error.to_string())
  }
  {
    quic,
    quic_error,
    clock,
    timer,
    coordination,
    config,
    settings: {
      ..@h3.H3Settings::default(),
      max_header_list: config.head_limits.max_head_bytes,
    },
    max_connection_age_ms,
    origins: Map([]),
    broken: Map([]),
    changed: coordination.signal(),
    closed: false,
  }
}

///|
/// QUIC connections open over all origins.
pub fn H3Backend::connections(self : H3Backend) -> Int32 {
  let mut n = 0
  for _, origin in self.origins {
    n += origin.conns.length()
  }
  n
}

///|
/// Closes every connection and refuses later sends with `Closed` in phase
/// Pool. Idempotent.
pub fn H3Backend::close(self : H3Backend) -> Unit {
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
fn H3Backend::notify(self : H3Backend) -> Unit {
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
/// Whether `origin`'s QUIC handshake failed not long ago.
fn H3Backend::is_broken(self : H3Backend, origin : String) -> Bool {
  match self.broken.get(origin) {
    Some(until) if until > self.clock.now_unix_ms() => true
    Some(_) => {
      self.broken.remove(origin)
      false
    }
    None => false
  }
}

///|
fn H3Backend::mark_broken(self : H3Backend, origin : String) -> Unit {
  if !self.broken.contains(origin) && self.broken.length() >= BROKEN_ORIGINS {
    let mut oldest : (String, Int64)? = None
    for key, until in self.broken {
      if oldest is None || until < oldest.unwrap().1 {
        oldest = Some((key, until))
      }
    }
    if oldest is Some((key, _)) {
      self.broken.remove(key)
    }
  }
  self.broken[origin] = self.clock.now_unix_ms() + BROKEN_MS
}

///|
fn H3Backend::sweep(self : H3Backend, origin : Origin) -> Unit {
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
    let idle = connection.active == 0 && connection.reserved == 0
    if idle &&
      (
        !connection.usable() ||
        now - connection.idle_since >= self.config.idle_max_ms.to_int64()
      ) {
      connection.close()
      continue
    }
    keep.push(connection)
  }
  origin.conns.clear()
  origin.conns.append(keep)
}

///|
/// A connection to `target`'s origin with a stream reserved on it, whether
/// it was already open, or `None` when its QUIC handshake did not complete
/// (the origin is then remembered as without HTTP/3).
async fn H3Backend::connection(
  self : H3Backend,
  target : Target,
  timer : @attempt.AttemptTimer,
  phases : Phases,
) -> (Connection, Bool)? raise @mttp_core.TransportError {
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
    if origin.conns.filter(c => c.usable()).last() is Some(connection) {
      if connection.has_room(self.settings.max_streams_bidi) {
        connection.reserved += 1
        return Some((connection, true))
      }
      timer.run(Pool, () => {
        connection.wait_until(() => {
          connection.has_room(self.settings.max_streams_bidi) ||
          !connection.usable()
        }) catch {
          @mttp_core.TransportError(..) => ()
        }
      })
      continue
    }
    if self.is_broken(target.origin) {
      return None
    }
    if origin.dialing {
      let signal = self.changed
      timer.run(Pool, () => signal.wait())
      continue
    }
    origin.dialing = true
    let dialed = {
      defer {
        origin.dialing = false
        self.notify()
      }
      timer.run(Dial, () => self.dial(target, phases))
    }
    guard dialed is Some(connection) else {
      self.mark_broken(target.origin)
      return None
    }
    if self.closed {
      connection.close()
      raise closed_error()
    }
    origin.conns.push(connection)
    connection.reserved += 1
    return Some((connection, false))
  }
  abort("unreachable")
}

///|
/// Opens a QUIC connection to `target` and completes its handshake within
/// `HANDSHAKE_MS`; `None` when it does not (nothing listens on UDP, a
/// firewall drops it, or the server refuses the handshake). The address the
/// resolver gives first is tried first, then one of the other family: UDP
/// has no connect to tell which one listens, and `localhost` resolves to
/// `::1` where a server may listen on 127.0.0.1 only.
async fn H3Backend::dial(
  self : H3Backend,
  target : Target,
  phases : Phases,
) -> Connection? raise @mttp_core.TransportError {
  guard self.quic is Some(quic) else {
    raise @mttp_core.TransportError(
      kind=Connect,
      phase=Dial,
      detail="QUIC TLS: \{self.quic_error}",
    )
  }
  let port = target.port.to_uint16()
  let first = @socket.Addr::resolve(target.host, port~) catch {
    error =>
      raise @mttp_core.TransportError(
        kind=Connect,
        phase=Dial,
        detail="resolving \{target.host}: \{error}",
      )
  }
  let other = (try {
    let v4 = @socket.Addr::resolve(target.host, port~, protocol=OnlyV4)
    let v6 = @socket.Addr::resolve(target.host, port~, protocol=OnlyV6)
    Some(if first == v4 { v6 } else { v4 })
  } catch {
    _ => None
  }).filter(addr => addr != first)
  let started = self.clock.now_unix_ms()
  for addr in [Some(first), other] {
    guard addr is Some(addr) else { continue }
    let left = HANDSHAKE_MS - (self.clock.now_unix_ms() - started).to_int()
    if left <= 0 {
      return None
    }
    match self.attempt(quic, target, addr, left, phases) {
      Some(connection) => return Some(connection)
      None => continue
    }
  }
  None
}

///|
/// One handshake with `target` at `addr`, within `ms`.
async fn H3Backend::attempt(
  self : H3Backend,
  quic : @h3.ClientQuic,
  target : Target,
  addr : @socket.Addr,
  ms : Int32,
  phases : Phases,
) -> Connection? noraise {
  let udp = @socket.UdpClient(addr) catch { _ => return None }
  let conn = @h3.QuicConn::client(
    quic,
    host=target.host,
    remote_address=addr.to_string(),
    settings=self.settings,
  ) catch {
    _ => {
      udp.close()
      return None
    }
  }
  let connection = Connection::new(
    udp,
    conn,
    self.coordination,
    self.timer,
    self.clock,
  )
  let mut ok = false
  defer (if !ok { connection.close() })
  let finished = self.timer.within(ms, () => {
    connection.flush() catch {
      @mttp_core.TransportError(..) => return
    }
    connection.wait_until(() => connection.handshake) catch {
      @mttp_core.TransportError(..) => ()
    }
  })
  if !finished || !connection.handshake {
    return None
  }
  // Dialed and TlsDone only for the attempt that connected.
  phases.emit(Dialed(addr=target.address))
  phases.emit(TlsDone)
  ok = true
  Some(connection)
}

///|
/// Reports a send's phase events (Backend rule 13).
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
/// `H3Backend::send`.
pub impl @mttp_core.Backend for H3Backend with fn send(self, request, options) {
  self.send(request, options)
}

///|
/// `H3Backend::close`.
pub impl @mttp_core.Backend for H3Backend with fn close(self) {
  self.close()
}

///|
/// One exchange over HTTP/3. An origin that cannot be reached over QUIC
/// fails the send with `Connect` in phase Dial, so it is unsent; see
/// `try_send` for a send that leaves such a request to another backend.
pub async fn H3Backend::send(
  self : H3Backend,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
) -> @mttp_core.Response raise @mttp_core.TransportError {
  match self.try_send(request, options) {
    Some(response) => response
    None => {
      if request.body is Stream(cell) {
        cell.close()
      }
      raise @mttp_core.TransportError(
        kind=Connect,
        phase=Dial,
        detail="no QUIC handshake with the origin",
      )
    }
  }
}

///|
/// One exchange over HTTP/3, or `None` without any request byte sent when
/// the origin's QUIC handshake does not complete in a second, or failed in
/// the last five minutes; the request, its stream body untaken, is then
/// the caller's to send otherwise. `http` URLs, CONNECT and upgrades are
/// declined the same way. Every other failure raises as `send`'s do.
pub async fn H3Backend::try_send(
  self : H3Backend,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
) -> @mttp_core.Response? raise @mttp_core.TransportError {
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
  if !target.secure ||
    request.meth is Connect ||
    request.headers.contains("upgrade") ||
    self.is_broken(target.origin) {
    return None
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
  guard self.connection(target, timer, phases) is Some((connection, reused)) else {
    return None
  }
  let mut reserving = true
  defer (if reserving {
    connection.reserved -= 1
    connection.notify()
  })
  let source = match request.body {
    Stream(cell) => Some(cell.take())
    _ => None
  }
  defer (if source is Some(source) { source.close() })
  let first = match source {
    Some(source) => timer.run(Write, () => source.read_some())
    None => request.body.as_bytes()
  }
  reserving = false
  connection.reserved -= 1
  let has_body = match (first, source) {
    (Some(bytes), None) => bytes.length() > 0
    (Some(_), Some(_)) => true
    _ => false
  }
  let id = connection.quic.submit_request(fields, body=has_body) catch {
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
  let mut returned = false
  defer (if !returned { connection.release(stream) })
  match (first, source) {
    (Some(bytes), None) if has_body =>
      connection.quic.push(id, bytes, end=true) catch {
        _ => ()
      }
    (Some(piece), Some(_)) =>
      connection.quic.push(id, piece, end=false) catch {
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
            connection.quic.queued(id).unwrap_or(0) < 65536
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
            connection.quic.push(id, bytes, end=false) catch {
              _ => return
            }
          None => {
            connection.quic.push(id, b"", end=true) catch {
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
  Some(response)
}

///|
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
fn H3Backend::stream_failure(
  self : H3Backend,
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
  let phase = if stream.headers_sent { phase } else { Pool }
  if connection.goaway is Some(first) && stream.id >= first {
    return @mttp_core.TransportError(
      kind=Refused,
      phase~,
      detail="the server's GOAWAY did not take stream \{stream.id}",
    )
  }
  match stream.closed {
    Some(code) if code == @h3.H3_REQUEST_REJECTED =>
      @mttp_core.TransportError(
        kind=Refused,
        phase~,
        detail="the server rejected the request (H3_REQUEST_REJECTED)",
      )
    Some(code) =>
      @mttp_core.TransportError(
        kind=Network,
        phase~,
        detail="the stream was reset: HTTP/3 error \{code}",
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
fn H3Backend::response(
  self : H3Backend,
  connection : Connection,
  stream : Stream,
  status : Int32,
  headers : @mttp_core.Headers,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
  timer : @attempt.AttemptTimer,
) -> @mttp_core.Response {
  let attributes = @mttp_core.Attributes::empty().put(@mttp_core.protocol, "h3")
  let bodiless = request.meth is Head || status == 204 || status == 304
  if bodiless || (stream.ended && stream.buffered == 0) {
    connection.release(stream)
    return { ..@mttp_core.Response::new(status, headers~), attributes, }
  }
  let declared = match headers.get("content-length") {
    Some(text) => @string.parse_int64(text) catch { _ => -1L }
    None => -1L
  }
  let body = H3Body::{
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
priv struct H3Body {
  connection : Connection
  stream : Stream
  timer : @attempt.AttemptTimer
  budget : @attempt.BodyBudget
  declared : Int64?
  mut finished : Bool
}

///|
impl @mttp_core.BodyStream for H3Body with fn read_some(self) {
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
    connection.quic.consume(stream.id, bytes.length())
    connection.flush_if_idle()
    return Some(bytes)
  }
  let complete = stream.ended ||
    (
      stream.closed == Some(@h3.H3_NO_ERROR) &&
      (self.declared is None || self.declared == Some(self.budget.count()))
    )
  if complete {
    self.close_stream()
    return None
  }
  raise @mttp_core.TransportError(
    kind=Network,
    phase=Body,
    detail="the stream was reset before its body ended: HTTP/3 error \{stream.closed.unwrap_or(0L)}",
  )
}

///|
fn H3Body::close_stream(self : H3Body) -> Unit {
  self.finished = true
  self.connection.release(self.stream)
}

///|
impl @mttp_core.BodyStream for H3Body with fn close(self) {
  if !self.finished {
    self.close_stream()
  }
}

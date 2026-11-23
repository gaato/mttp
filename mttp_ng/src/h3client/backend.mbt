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
/// Takes the connections of `origin` that are done (idle, and unusable or
/// idle too long) out of it, and returns them for the caller to close.
fn H3Backend::sweep(self : H3Backend, origin : Origin) -> Array[Connection] {
  let now = self.clock.now_unix_ms()
  let keep = []
  let done = []
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
      done.push(connection)
      continue
    }
    keep.push(connection)
  }
  origin.conns.clear()
  origin.conns.append(keep)
  done
}

///|
/// A connection to `target`'s origin with a stream reserved on it, whether
/// it was already open, or `None` when its QUIC handshake did not complete
/// (the origin is then remembered as without HTTP/3).
async fn H3Backend::connection(
  self : H3Backend,
  target : @mux.Target,
  timer : @attempt.AttemptTimer,
  phases : @mux.Phases,
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
    // Taken out of the origin first, so no other send picks them meanwhile.
    for connection in self.sweep(origin) {
      connection.close_gracefully()
    }
    if origin.conns.filter(c => c.usable()).last() is Some(connection) {
      if connection.has_room(self.settings.max_streams_bidi) {
        connection.reserved += 1
        return Some((connection, true))
      }
      timer.run(Pool, () => {
        connection.wait_for(() => {
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
      connection.close_gracefully()
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
  target : @mux.Target,
  phases : @mux.Phases,
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
  target : @mux.Target,
  addr : @socket.Addr,
  ms : Int32,
  phases : @mux.Phases,
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
    connection.send_output() catch {
      @mttp_core.TransportError(..) => return
    }
    connection.wait_for(() => connection.handshake) catch {
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
  let body = @mux.RequestSource::new(request)
  defer body.finish()
  if self.closed {
    raise closed_error()
  }
  options.validate()
  match options.body {
    Exchange(..) | Stream(..) => ()
    @mttp_core.BodyTiming::.. =>
      raise @mux.invalid("a BodyTiming this backend does not know")
  }
  if self.config.max_body_bytes is Some(n) && n < 0 {
    raise @mux.invalid("negative body byte ceiling")
  }
  let target = @mux.target(request)
  if !target.secure ||
    request.meth is Connect ||
    request.headers.contains("upgrade") ||
    self.is_broken(target.origin) {
    body.hand_over()
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
  let fields = @mux.request_fields(request, target)
  let phases = @mux.Phases::new(request)
  defer phases.end()
  guard self.connection(target, timer, phases) is Some((connection, reused)) else {
    body.hand_over()
    return None
  }
  let mut reserving = true
  defer (if reserving {
    connection.reserved -= 1
    connection.notify()
  })
  let source = body.take()
  let first = match source {
    Some(source) => timer.run(Write, () => source.read_some())
    None => request.body.as_bytes()
  }
  reserving = false
  connection.reserved -= 1
  let response = @mux.exchange(
    connection,
    self.coordination,
    fields,
    request,
    options,
    timer,
    phases,
    reused~,
    source,
    first,
    {
      head_max: self.config.head_limits.max_head_bytes,
      max_body_bytes: self.config.max_body_bytes,
      queue_bytes: QUEUE_BYTES,
    },
    protocol="h3",
  )
  Some(response)
}

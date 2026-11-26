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
/// `https` URLs go over TLS offering `h2` and `http/1.1` by ALPN; a server
/// that chooses `http/1.1`, or neither, gets the request over HTTP/1.1 on
/// that same connection, through gaato/mttp_core's HTTP/1 client, and its
/// origin keeps HTTP/1.1 for ten minutes. `http` URLs go over HTTP/1.1, or
/// over cleartext HTTP/2 with prior knowledge (h2c) when built with
/// `h2c=true`, for servers known to speak it.
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
  /// Origins whose server chose http/1.1, until when.
  priv http11 : Map[String, Int64]
  priv handoff : HandoffDialer
  priv fallback : @h1client.Client
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
/// how long a connection may stay idle (`idle_max_ms`); all of it, the proxy
/// and the connection caps included, applies to the requests that go over
/// HTTP/1.1. An `https` origin with a proxy configured for https is reached
/// through the proxy's tunnel, as the HTTP/1 client reaches it
/// (`@h1client.https_tunnel`, NO_PROXY applied), and gets HTTP/2 when it
/// chooses h2 there; one that chooses http/1.1 goes to the HTTP/1 client,
/// through the proxy too. An `http` URL with a proxy goes over HTTP/1.1 to
/// the proxy, which forwards it. `max_connection_age_ms`
/// retires a connection at that age: it takes no new stream, and closes when
/// its last one ends. `h2c` lets `http` URLs speak HTTP/2 with prior
/// knowledge.
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
  // The ALPN lists are fixed and valid, and every Trust case is known.
  let tls = @tls.ClientTls::new(trust~, alpn=["h2", "http/1.1"]) catch {
    _ => abort("ClientTls::new refused a fixed configuration")
  }
  let http11_tls = @tls.ClientTls::new(trust~, alpn=["http/1.1"]) catch {
    _ => abort("ClientTls::new refused a fixed configuration")
  }
  let handoff = {
    tcp: dialer,
    tls: http11_tls,
    coordination,
    parked: [],
    handed: [],
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
    http11: Map([]),
    handoff,
    fallback: @h1client.Client::new(
      dialer=handoff,
      clock~,
      timer~,
      coordination~,
      config~,
      max_connection_age_ms?,
    ),
    changed: coordination.signal(),
    closed: false,
  }
}

///|
/// HTTP/2 connections open over all origins, busy or idle.
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
  self.fallback.close()
  self.handoff.close()
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
/// How a request goes.
priv enum Route {
  /// On a stream of this connection, which was already open or not.
  H2(Connection, reused~ : Bool)
  /// Over HTTP/1.1: the server chose it by ALPN on the connection this send
  /// dialled, which waits in the hand-over dialer.
  Http11
}

///|
/// A connection to `target`'s origin with room for one more stream, which
/// it reserves, or `Http11` when the dial found that the server speaks
/// HTTP/1.1 only.
async fn H2Backend::connection(
  self : H2Backend,
  target : @mux.Target,
  timer : @attempt.AttemptTimer,
  phases : @mux.Phases,
) -> Route raise @mttp_core.TransportError {
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
        return H2(connection, reused=true)
      }
      // Every stream the server allows is in use: wait for one to end,
      // reading the connection meanwhile.
      timer.run(Pool, () => {
        connection.wait_for(() => connection.has_room() || !connection.usable()) catch {
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
    let dialed = {
      defer {
        origin.dialing = false
        self.notify()
      }
      timer.run(Dial, () => self.dial(target, phases))
    }
    guard dialed is Some(connection) else { return Http11 }
    if self.closed {
      connection.close()
      raise closed_error()
    }
    origin.conns.push(connection)
    connection.reserved += 1
    return H2(connection, reused=false)
  }
  abort("unreachable")
}

///|
/// Opens a connection to `target`: TCP through the dialer, then TLS with
/// ALPN for `https`, or cleartext HTTP/2 for `http` with `h2c`. `None` when
/// the server did not choose `h2`: the TLS connection is parked for the
/// HTTP/1 client, and the origin remembered as HTTP/1.1.
async fn H2Backend::dial(
  self : H2Backend,
  target : @mux.Target,
  phases : @mux.Phases,
) -> Connection? raise @mttp_core.TransportError {
  // Through the proxy configured for https, as h1client would route the
  // origin (`no_proxy` included); directly otherwise.
  let tunnel = if target.secure && self.config.proxy.https is Some(_) {
    @h1client.https_tunnel(self.dialer, self.config, url=target.origin)
  } else {
    None
  }
  let tunneled = tunnel is Some(_)
  let tcp = match tunnel {
    Some(conn) => conn
    None => self.dialer.connect(host=target.host, port=target.port)
  }
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
      self.remember_http11(target.origin)
      // h1client reaches a proxied origin through the proxy, not through
      // a hand-over to the origin's address: it makes its own tunnel.
      if tunneled {
        tls.close()
      } else {
        self.handoff.park(target.host, target.port, tls)
      }
      return None
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
  Some(
    Connection::new(conn, session, self.coordination, self.timer, self.clock),
  )
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
/// closed on every exit. CONNECT and protocol upgrades go over HTTP/1.1,
/// which has them. A final response before the whole request body was sent
/// stops the upload; the stream is reset once the response ends, unless the
/// server already ended it.
pub async fn H2Backend::send(
  self : H2Backend,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
) -> @mttp_core.Response raise @mttp_core.TransportError {
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
  // A forward proxy takes HTTP/1.1; an https origin goes through the
  // proxy's tunnel, over HTTP/2 when it chooses h2 (`dial`).
  let forwarded = !target.secure && self.config.proxy.http is Some(_)
  if (!target.secure && !self.h2c) ||
    forwarded ||
    request.meth is Connect ||
    request.headers.contains("upgrade") ||
    self.speaks_http11(target.origin) {
    body.hand_over()
    return self.fallback.send(request, options)
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
  let (connection, reused) = match self.connection(target, timer, phases) {
    H2(connection, reused~) => (connection, reused)
    Http11 => {
      phases.end()
      body.hand_over()
      let (request, options) = handed_over(request, options, timer)
      return self.fallback.send(request, options)
    }
  }
  // The stream reserved on the connection is given back on every exit
  // before it opens.
  let mut reserving = true
  defer (if reserving {
    connection.reserved -= 1
    connection.notify()
  })
  let source = body.take()
  // The request body's first piece, read before anything is sent (rule 3).
  let first = match source {
    Some(source) => timer.run(Write, () => source.read_some())
    None => request.body.as_bytes()
  }
  reserving = false
  connection.reserved -= 1
  @mux.exchange(
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
    protocol="h2",
  )
}

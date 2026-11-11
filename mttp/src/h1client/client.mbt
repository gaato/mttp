///|
/// An HTTP/1.1 client over the `rt` ports: a pool of connections per
/// origin, bounded heads and bodies, and per-phase deadlines. It implements
/// `@mttp.Backend`, so it moves raw bytes: no redirects, retries, cookies or
/// content decoding, and no `Accept-Encoding` of its own.
///
/// A response owns its connection until its body is read to the end, which
/// parks a reusable connection for the next request to the same origin, or
/// closed, which closes it. TLS and its trust settings belong to the
/// `Dialer`; the client reads no host environment.
pub struct Client {
  priv dialer : &@rt.Dialer
  priv clock : &@rt.Clock
  priv timer : &@rt.Timer
  priv coordination : &@rt.Coordination
  priv config : ClientConfig
  priv proxies : Proxies
  priv pool : IdlePool[Wire]
  priv slots : Slots
}

///|
/// Set to `true` on a response that came from resending the request on a
/// fresh connection, after the reused idle connection it was first sent on
/// failed before any response byte arrived. Only a request with a
/// replayable body that is idempotent or marked `replay_safe` is resent,
/// and only once. The resend is a repair of a stale connection, not a
/// policy attempt.
pub let stale_resend : @mttp.AttributeKey[Bool] = @mttp.AttributeKey::new(
  "h1client.stale_resend",
)

///|
/// Creates a client with `config` over the given ports.
///
/// ```mbt check
/// test {
///   let driver = @driver.Driver::new()
///   let conn = @sim.ScriptedConn::new([
///     Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"),
///   ])
///   let client = @h1client.Client::new(
///     dialer=@sim.ScriptedDialer::new([conn]),
///     clock=@sim.SimClock::new(driver),
///     timer=@sim.SimTimer::new(driver),
///     coordination=@sim.SimCoordination::new(driver),
///     config=@h1client.ClientConfig::default(),
///   )
///   driver.run(() => {
///     let response = client.send(
///       @mttp.Request::get("http://example.test/"),
///       @mttp.SendOptions::default(),
///     )
///     guard response.body is Stream(body) else { fail("expected a body") }
///     assert_eq(@mttp.read_bounded(body.take(), 1024), b"hi")
///     assert_eq(client.idle_connections(), 1)
///     client.close()
///   })
///   assert_eq(conn.closes(), 1)
/// }
/// ```
pub fn Client::new(
  dialer~ : &@rt.Dialer,
  clock~ : &@rt.Clock,
  timer~ : &@rt.Timer,
  coordination~ : &@rt.Coordination,
  config~ : ClientConfig,
) -> Client {
  {
    dialer,
    clock,
    timer,
    coordination,
    config,
    proxies: Proxies::new(config.proxy),
    pool: IdlePool::new(
      max_total=config.max_idle_connections,
      max_per_origin=config.max_idle_per_origin,
      idle_max_ms=config.idle_max_ms,
    ),
    slots: Slots::new(
      coordination~,
      max_total?=config.max_connections,
      max_per_origin?=config.max_connections_per_origin,
    ),
  }
}

///|
/// The number of parked idle connections over all origins.
pub fn Client::idle_connections(self : Client) -> Int32 {
  self.pool.count()
}

///|
/// Closes the parked connections and refuses queued and later sends with
/// `Closed` in phase Pool. Responses in flight keep their connections;
/// finishing them closes the connection instead of parking it. Idempotent.
pub impl @mttp.Backend for Client with fn close(self) {
  for wire in self.pool.drain() {
    wire.close()
  }
  self.slots.stop()
}

///|
/// Sends one request: see `Client` and CONTRACT.md (Backend; SendOptions and
/// BodyTiming).
///
/// The request is validated before any I/O, and so are `options`. A stream
/// body is taken and its first piece read before anything is written, and
/// it is closed on every exit. The connection comes from the idle pool when
/// one with the same User-Agent is parked for the origin, otherwise it is
/// dialled; a reused connection that fails before any response byte arrived
/// is replaced once by a fresh one, if the body is replayable and the
/// request idempotent (`@mttp.is_idempotent`).
///
/// With `Exchange(max_bytes)`, `timeout_ms` covers the head and the whole
/// body, and at most `max_bytes` (and `ClientConfig.max_body_bytes`) body
/// bytes are read from the wire. With `Stream(idle_ms)`, `timeout_ms` ends
/// at the head, each body read waits at most `idle_ms` (and the read
/// limit), and only the configured ceiling bounds the bytes.
pub impl @mttp.Backend for Client with fn send(self, request, options) {
  self.send_request(request, options)
}

///|
/// The Backend operations as methods of the client.
pub extend Client with @mttp.Backend::{send, close}

///|
async fn Client::send_request(
  self : Client,
  request : @mttp.Request,
  options : @mttp.SendOptions,
) -> @mttp.Response raise @mttp.TransportError {
  // Taken first, so that every exit below closes the stream: a refusal, a
  // failure, cancellation, or the end of the upload.
  let stream = match request.body {
    Stream(cell) => Some(cell.take())
    _ => None
  }
  defer (if stream is Some(stream) { stream.close() })
  if self.pool.control.closed {
    raise closed()
  }
  options.validate()
  if self.config.max_body_bytes is Some(n) && n < 0 {
    raise invalid("negative body byte ceiling")
  }
  let target = target(request)
  let route = self.proxies.route(target)
  let key = route.key(target.origin)
  let headers = route.headers(request.headers)
  let headers = if headers.contains("host") {
    headers
  } else {
    headers.add("host", target.host_field)
  }
  let framing = request_framing(request)
  let head = @h1.write_request_head(
    request.meth,
    route.target(target, request.meth),
    headers,
    framing,
    Http11,
  ) catch {
    @h1.ParseError(detail~, ..) => raise invalid(detail)
  }
  let limits : Timeouts = {
    pool: self.config.pool_timeout_ms,
    connect: self.config.connect_timeout_ms,
    write: self.config.write_timeout_ms,
    read: self.config.read_timeout_ms,
  }
  let timer = PhaseTimer::new(
    self.clock,
    self.timer,
    limits,
    options.timeout_ms,
  )
  let upload : Upload = match stream {
    Some(stream) => Stream(stream, timer.run(Write, () => stream.read_some()))
    None => Bytes(request.body.as_bytes().unwrap_or(b""))
  }
  self.slots.acquire(key, timer)
  let mut transferred = false
  defer (if !transferred { self.slots.release(key) })
  let agent = request.headers.get("user-agent")
  let resendable = request.body.is_replayable() && @mttp.is_idempotent(request)
  let mut fresh = false
  for ;; {
    if self.pool.control.closed {
      raise closed()
    }
    let (cached, expired) = self.pool.take(
      key,
      agent,
      now=self.clock.now_unix_ms(),
    )
    for old in expired {
      old.close()
    }
    // After a stale connection, the others parked as long are suspect too.
    let cached = if fresh {
      if cached is Some(old) {
        old.close()
      }
      None
    } else {
      cached
    }
    let reused = cached is Some(_)
    let wire = match cached {
      Some(wire) => {
        wire.received = 0L
        wire
      }
      None =>
        timer.run(Dial, () => {
          dial_route(self.dialer, target, route, agent, self.config.head_limits)
        })
    }
    let mut owned = true
    defer (if owned { wire.close() })
    let exchanged = exchange(
      wire,
      head,
      upload,
      framing,
      timer,
      self.config.head_limits,
      self.coordination,
    ) catch {
      @mttp.TransportError(kind=Network, ..) if reused &&
        resendable &&
        wire.received == 0L => {
        fresh = true
        continue
      }
      error => raise error
    }
    let response = exchanged.head
    let body_framing = @h1.response_framing(
      response.headers,
      status=response.status,
      meth=request.meth,
    ) catch {
      error => raise failure(Head, error)
    }
    let keep_alive = exchanged.uploaded &&
      !(body_framing is UntilClose) &&
      response.status != 101 &&
      request.meth != Connect &&
      !connection_token(request.headers, "close") &&
      !connection_token(response.headers, "close") &&
      (
        response.version == Http11 ||
        connection_token(response.headers, "keep-alive")
      )
    let attributes = if fresh {
      @mttp.Attributes::empty().put(stale_resend, true)
    } else {
      @mttp.Attributes::empty()
    }
    owned = false
    transferred = true
    if body_framing is NoBody || body_framing == Length(0L) {
      self.release(key, agent, wire, keep_alive)
      return {
        ..@mttp.Response::new(response.status, headers=response.headers),
        attributes,
      }
    }
    let (body_timer, limit) = match options.body {
      Stream(idle_ms~) =>
        (
          PhaseTimer::new(
            self.clock,
            self.timer,
            { ..limits, read: min_limit(idle_ms, limits.read), },
            None,
          ),
          self.config.max_body_bytes,
        )
      Exchange(max_bytes~) =>
        (
          timer,
          Some(min_limit(self.config.max_body_bytes, Some(max_bytes)).unwrap()),
        )
      @mttp.BodyTiming::.. => (timer, self.config.max_body_bytes)
    }
    let reader = ResponseBody::new(
      self, key, agent, wire, body_framing, body_timer, limit, keep_alive,
    )
    let length = match body_framing {
      Length(n) => Some(n)
      _ => None
    }
    return {
      ..@mttp.Response::new(
        response.status,
        headers=response.headers,
        body=Stream(@mttp.StreamBody::new(reader, length?)),
      ),
      attributes,
    }
  }
}

///|
/// The smaller of two optional limits.
fn min_limit(a : Int32?, b : Int32?) -> Int32? {
  match (a, b) {
    (Some(a), Some(b)) => Some(a.min(b))
    (Some(_), None) => a
    (None, _) => b
  }
}

///|
/// How the request body is framed. An empty body of a method that expects
/// content (POST, PUT, PATCH) sends `Content-Length: 0`; for other methods
/// it sends no framing field, as RFC 9110 §8.6 asks.
fn request_framing(request : @mttp.Request) -> @h1.Framing {
  match request.body.length() {
    Some(0L) if !(request.meth is (Post | Put | Patch)) => NoBody
    Some(n) => Length(n)
    None => Chunked
  }
}

///|
/// Parks a reusable connection with nothing left unread, or closes it, and
/// frees its slot.
fn Client::release(
  self : Client,
  key : String,
  agent : String?,
  wire : Wire,
  reusable : Bool,
) -> Unit {
  if reusable && wire.pending.is_empty() && !wire.closed {
    for
      rejected in self.pool.put(key, agent, wire, now=self.clock.now_unix_ms()) {
      rejected.close()
    }
  } else {
    wire.close()
  }
  self.slots.release(key)
}

///|
/// Whether a Connection field lists `token`.
fn connection_token(headers : @mttp.Headers, token : String) -> Bool {
  headers
  .get_all("connection")
  .iter()
  .any(value => {
    value
    .split(",")
    .any(part => part.trim(chars=" \t").to_owned().to_lower() == token)
  })
}

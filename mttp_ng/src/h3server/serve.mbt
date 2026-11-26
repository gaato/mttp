// An HTTP/3 server on one UDP socket: datagrams are routed to their
// connection by their Destination Connection ID, so a client may move (or
// its NAT rebind) without losing its connection; new connections start from
// a client's Initial, after a Retry when many handshakes are open; and a
// task per request stream runs the handler and writes its response through
// `@mux.ServerContext`, the stream code HTTP/2's server shares. A closed
// connection's IDs stay routed for its closing or draining period (RFC
// 9000, section 10.2), and a short header packet for no connection is
// answered with a Stateless Reset.

///|
/// A request stream and the task that serves it.
priv struct Entry {
  stream : @mux.ServerStream
  mut task : @async.Task[Unit]?
}

///|
/// One connection.
priv struct Served {
  /// The client's address now, and its text.
  mut peer : @socket.Addr
  mut peer_text : String
  udp : @socket.UdpServer
  quic : @h3.QuicConn
  /// The connection IDs routed to it: the DCID of its first Initial, then
  /// those it issued and has not retired.
  ids : Array[Bytes]
  routes : Map[Bytes, Route]
  streams : Map[Int64, Entry]
  /// Handlers running, cancelled ones still finishing included.
  mut handlers : Int32
  changes : @mux.Changes
  /// Since when no handler runs (from the first datagram, for a new
  /// connection), for `header_timeout_ms`.
  mut idle_since : Int64
}

///|
/// Where datagrams for a connection ID go.
priv enum Route {
  Live(Served)
  Ended(Ended)
}

///|
/// A closed connection in its closing or draining period: three probe
/// timeouts in which its IDs stay routed, so that a late packet is neither
/// taken for a new connection nor answered with a Stateless Reset.
priv struct Ended {
  ids : Array[Bytes]
  until : Int64
  /// The CONNECTION_CLOSE this end sent (the closing period), sent again
  /// when packets arrive; `None` when the client closed (the draining
  /// period), in which nothing is sent.
  close : Bytes?
  /// Packets received since the close: the close goes again at the 1st,
  /// 2nd, 4th, 8th..., so a client that keeps sending gets fewer answers,
  /// as section 10.2.1 asks.
  mut received : Int32
  /// The client's address when the connection closed, one QUIC had
  /// validated: the close goes again only to it. A connection ID is no
  /// proof of who sends (another client of the server sees one, and a
  /// source address can be forged), and the close may be larger than the
  /// packet that asks for it, so answering any address would reflect it
  /// at a victim (Codex's review of #59).
  peer : String
}

///|
/// Sends what the connection has to say, each datagram to its own address,
/// and routes the connection IDs it issued meanwhile (NEW_CONNECTION_ID)
/// before the client can use them.
async fn Served::send(self : Served) -> Unit noraise {
  let datagrams = self.quic.addressed_datagrams() catch { _ => [] }
  self.route()
  for pair in datagrams {
    let (address, datagram) = pair
    let to = if address == self.peer_text || address.is_empty() {
      self.peer
    } else {
      @socket.Addr::parse(address) catch {
        _ => continue
      }
    }
    self.udp.send(datagram, to) catch {
      _ => ()
    }
  }
}

///|
/// Brings the routes in line with the connection's IDs: new ones routed to
/// it, retired ones dropped. The first, its Initial's DCID, stays.
fn Served::route(self : Served) -> Unit {
  let now = self.quic.connection_ids()
  for id in now {
    if !self.ids.contains(id) {
      self.ids.push(id)
      self.routes[id] = Live(self)
    }
  }
  let mut i = 1
  while i < self.ids.length() {
    let id = self.ids[i]
    if now.contains(id) {
      i += 1
    } else {
      ignore(self.ids.remove(i))
      self.routes.remove(id)
    }
  }
}

///|
/// Follows the client to its address now, after a datagram: QUIC moves a
/// connection's path once it validated the new one.
fn Served::follow(self : Served) -> Unit {
  let now = self.quic.remote_address()
  if now.is_empty() || now == self.peer_text {
    return
  }
  let addr = @socket.Addr::parse(now) catch { _ => return }
  self.peer = addr
  self.peer_text = now
}

///|
impl @mux.ServerConn for Served with fn submit_response(self, id, fields, body~) {
  let ok = try {
    self.quic.submit_response(id, fields, body~)
    true
  } catch {
    _ => false
  }
  self.changes.notify()
  ok
}

///|
impl @mux.ServerConn for Served with fn send_continue(self, id) {
  let ok = try {
    self.quic.submit_info(id, [(":status", "100")])
    true
  } catch {
    _ => false
  }
  self.changes.notify()
  ok
}

///|
impl @mux.ServerConn for Served with fn push(self, id, data, end~) {
  let ok = try {
    self.quic.push(id, data, end~)
    true
  } catch {
    _ => false
  }
  self.changes.notify()
  ok
}

///|
impl @mux.ServerConn for Served with fn end_with_trailers(self, id, fields) {
  let ok = try {
    self.quic.end_with_trailers(id, fields)
    true
  } catch {
    _ => false
  }
  self.changes.notify()
  ok
}

///|
impl @mux.ServerConn for Served with fn queued(self, id) {
  self.quic.queued(id).unwrap_or(0)
}

///|
impl @mux.ServerConn for Served with fn consume(self, id, len) {
  self.quic.consume(id, len)
}

///|
impl @mux.ServerConn for Served with fn abort(self, id) {
  self.quic.reset(id, @h3.H3_INTERNAL_ERROR)
}

///|
/// STOP_SENDING with H3_NO_ERROR (RFC 9114, section 4.1): unlike HTTP/2's
/// reset, it ends only what the client sends, so the response still goes.
impl @mux.ServerConn for Served with fn stop_reading(self, stream) {
  self.quic.reset(stream.id, @h3.H3_NO_ERROR, read_only=true)
  self.send()
}

///|
impl @mux.ServerConn for Served with fn gone(self) {
  self.quic.closed()
}

///|
impl @mux.ServerConn for Served with fn flush(self) {
  self.send()
}

///|
/// The listener's state.
priv struct Listener {
  udp : @socket.UdpServer
  /// Live connections, by a number of their own.
  conns : Map[Int32, Served]
  mut next_id : Int32
  routes : Map[Bytes, Route]
  /// Closed connections in their closing or draining period, oldest first;
  /// at most `max_connections`.
  ended : Array[Ended]
  /// The listener's own keys of reset and Retry tokens.
  keys : @h3.ServerKeys
  /// Stateless Resets sent in the current second, and when it began.
  mut resets : Int32
  mut resets_since : Int64
  changes : @mux.Changes
  coordination : &@rt.Coordination
  timer : &@rt.Timer
  clock : &@rt.Clock
  limits : @h1server.ServerLimits
  settings : @h3.H3Settings
  handler : @mttp_core.Handler
  auto_date : Bool
  on_error : (@mttp_core.TransportError) -> Unit
  /// The server stops: no new connection, and each is told to go away.
  mut stopping : Bool
  /// 0: serving; 1: the GOAWAY notice went; 2: the last GOAWAY went.
  mut going : Int32
  mut notice_at : Int64
}

///|
/// One round trip, as HTTP/2's server takes it: the time between the
/// GOAWAY notice and the GOAWAY naming the last stream (RFC 9114, section
/// 5.2), and how often a stopping listener looks at its connections.
const STOP_POLL_MS : Int32 = 250

///|
/// The most a closing or draining period lasts, whatever the probe timeout.
const ENDED_MAX_MS : Int64 = 30000

///|
/// Stateless Resets a server sends in a second at most. A reset is
/// smaller than the packet it answers, so it amplifies nothing; the bound
/// keeps a flood of short packets with made-up connection IDs from being
/// reflected at its rate.
const RESETS_PER_SECOND : Int32 = 100

///|
/// Serves `handler` over HTTP/3 on UDP `addr` (`host:port`), with `quic`'s
/// certificate, until cancelled. Cancelling it stops it as `@server.serve`
/// stops: no new connection is taken, each connection is told to go away
/// (GOAWAY, first a notice, then the last stream it will process), a stream
/// marked `@mttp_core.close_on_shutdown` is ended, and the requests in
/// flight get `limits.drain_ms` to finish; a connection is closed with
/// H3_NO_ERROR once none runs, and every one when the time is out.
/// `limits` applies as it does to HTTP/2 (`serve_h2_conn`):
/// the body bound, the timeouts, the header bound and `max_connections`
/// (more clients' Initials are dropped), and `header_timeout_ms` for a
/// connection on which no handler runs, which is then closed with
/// H3_NO_ERROR. Once a quarter of `max_connections` (at least one) are
/// connections whose handshake has not completed, a new client is first
/// sent a Retry, and gets a connection only when it answers from its
/// address: Initials from forged addresses then hold no more than that
/// quarter. Datagrams are routed by connection ID, so a client may move to
/// another address. `settings` gives the streams and
/// windows. Requests carry the `protocol` attribute `h3` and
/// `connection_scheme` `https`. While `settings.max_streams_bidi` handlers
/// of a connection run (cancelled ones still finishing included), a new
/// request is refused with H3_REQUEST_REJECTED, as HTTP/2's server refuses
/// one with REFUSED_STREAM. `on_listen` hears the bound address.
pub async fn serve(
  handler : @mttp_core.Handler,
  addr~ : String,
  quic~ : @h3.ServerQuic,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
  settings~ : @h3.H3Settings = @h3.H3Settings::default(),
  auto_date~ : Bool = true,
  on_listen~ : (String) -> Unit = _ => (),
  on_error~ : (@mttp_core.TransportError) -> Unit = _ => (),
) -> Unit raise @server.ListenError {
  let bound = @socket.Addr::parse(addr) catch {
    error =>
      raise @server.ListenError::Bind(
        detail="invalid address \{addr}: \{error}",
      )
  }
  let udp = @socket.UdpServer(bound) catch {
    error =>
      raise @server.ListenError::Bind(
        detail="could not bind UDP \{addr}: \{error}",
      )
  }
  defer udp.close()
  let bound_address = udp.addr.to_string()
  on_listen(bound_address)
  let clock = @runtime.AsyncClock::new()
  let timer = @runtime.ClockTimer::new(clock~)
  let coordination = @runtime.RuntimeCoordination::new()
  let listener = {
    udp,
    conns: Map([]),
    next_id: 0,
    routes: Map([]),
    ended: [],
    keys: @h3.ServerKeys::new() catch {
      error =>
        raise @server.ListenError::Bind(detail="HTTP/3 server keys: \{error}")
    },
    resets: 0,
    resets_since: 0L,
    changes: @mux.Changes::new(coordination, clock, timer),
    coordination,
    timer,
    clock,
    limits,
    settings: { ..settings, max_header_list: limits.max_header_bytes, },
    handler,
    auto_date,
    on_error,
    stopping: false,
    going: 0,
    notice_at: 0L,
  }
  @async.with_task_group(outer => {
    // Whatever is left (a listener that failed): every client hears the
    // close at once.
    defer {
      @async.protect_from_cancel(() => listener.expire())
      for _, conn in listener.conns {
        conn.quic.free()
      }
    }
    // The listener and its handlers run beyond a cancellation, which
    // starts the stop, as gaato/mttp's listener does.
    let worker = outer.spawn(allow_failure=true, () => {
      @async.protect_from_cancel(() => {
        @async.with_task_group(group => listener.run(group, quic, bound_address))
      })
    })
    let result = @async.handle_cancellation(() => worker.wait())
    if result is None {
      @async.protect_from_cancel(() => {
        listener.stop()
        let drained = @async.with_timeout_opt(limits.drain_ms, () => {
          worker.wait()
        }) catch {
          _ => Some(())
        }
        if drained is None {
          listener.expire()
          worker.wait() catch {
            _ => ()
          }
        }
      })
      @async.pause()
    }
  }) catch {
    error =>
      raise @server.ListenError::Accept(
        detail="HTTP/3 listener failed: \{error}",
      )
  }
}

///|
/// When `conn`, idle, is closed: `header_timeout_ms` after its last handler
/// ended or its first datagram, as HTTP/2's server ends a connection
/// without streams; `None` while a handler runs. A request whose headers
/// never complete starts no handler, so a client that keeps the connection
/// alive with QUIC traffic alone holds its `max_connections` slot no longer.
fn Listener::idle_deadline(self : Listener, conn : Served) -> Int64? {
  if conn.handlers > 0 || conn.quic.closed() {
    None
  } else {
    Some(conn.idle_since + self.limits.header_timeout_ms.to_int64())
  }
}

///|
async fn Listener::run(
  self : Listener,
  group : @async.TaskGroup,
  quic : @h3.ServerQuic,
  bound_address : String,
) -> Unit {
  let buffer = FixedArray::make(65536, b'\x00')
  while !(self.stopping && self.conns.is_empty()) {
    // The nearest timer of any connection, or idle deadline, bounds the
    // wait; while stopping, the next look at the connections too.
    let mut wait = if self.stopping { STOP_POLL_MS } else { 1000 }
    let now = self.clock.now_unix_ms()
    for _, conn in self.conns {
      if conn.quic.expiry_ms() is Some(ms) && ms < wait {
        wait = ms
      }
      if self.idle_deadline(conn) is Some(at) {
        let ms = (at - now).max(0L).min(1000L).to_int()
        if ms < wait {
          wait = ms
        }
      }
    }
    let got : Ref[(Int32, @socket.Addr)?] = Ref(None)
    if wait > 0 {
      ignore(
        self.timer.within(wait, () => {
          got.val = Some(self.udp.recv_into(buffer.mut_view())) catch {
            _ => None
          }
        }),
      )
    }
    if got.val is Some((n, peer)) {
      let datagram = Bytes::from_array(buffer[:n])
      self.receive(group, quic, bound_address, datagram, peer)
    }
    let gone = []
    let now = self.clock.now_unix_ms()
    self.expire_ended(now)
    // One round trip after the notice, the GOAWAY naming the last request
    // stream; once it went, a connection with no handler is done.
    if self.going == 1 && now - self.notice_at >= STOP_POLL_MS.to_int64() {
      self.going = 2
      for _, conn in self.conns {
        conn.quic.shutdown(notice=false) catch {
          _ => ()
        }
        conn.send()
      }
    }
    for key, conn in self.conns {
      if self.going == 2 && conn.handlers == 0 && !conn.quic.closed() {
        conn.quic.close()
        conn.send()
      }
      if self.idle_deadline(conn) is Some(at) && now >= at {
        conn.quic.close()
        conn.send()
      }
      if conn.quic.expiry_ms() == Some(0) {
        conn.quic.on_expiry() catch {
          _ => ()
        }
        self.dispatch(group, conn)
        conn.send()
      }
      if conn.quic.closed() && conn.handlers == 0 {
        gone.push(key)
      }
    }
    for key in gone {
      if self.conns.get(key) is Some(conn) {
        self.retire(conn, now)
      }
      self.conns.remove(key)
    }
  }
}

///|
/// Frees a closed connection whose handlers ended. Its IDs stay routed for
/// three probe timeouts when it closed by a CONNECTION_CLOSE, either end's
/// (RFC 9000, section 10.2); a connection that timed out is forgotten at
/// once (section 10.1), and a late packet of it gets a Stateless Reset.
fn Listener::retire(self : Listener, conn : Served, now : Int64) -> Unit {
  let close = conn.quic.close_datagram()
  if close is None && !conn.quic.closed_by_peer() {
    for id in conn.ids {
      self.routes.remove(id)
    }
  } else {
    let period = (conn.quic.pto_ms() * 3L).min(ENDED_MAX_MS)
    let ended = {
      ids: conn.ids,
      until: now + period,
      close,
      received: 0,
      peer: conn.peer_text,
    }
    for id in conn.ids {
      self.routes[id] = Ended(ended)
    }
    self.ended.push(ended)
    // Bounded as the live connections are: past it, the oldest period
    // ends early, which RFC 9000 allows where it must (section 10.2).
    if self.ended.length() > self.limits.max_connections {
      self.unroute(self.ended.remove(0))
    }
  }
  conn.quic.free()
}

///|
fn Listener::unroute(self : Listener, ended : Ended) -> Unit {
  for id in ended.ids {
    if self.routes.get(id) is Some(Ended(e)) && physical_equal(e, ended) {
      self.routes.remove(id)
    }
  }
}

///|
/// Ends the closing and draining periods that are over.
fn Listener::expire_ended(self : Listener, now : Int64) -> Unit {
  if self.ended.is_empty() {
    return
  }
  let kept = []
  for ended in self.ended {
    if ended.until <= now {
      self.unroute(ended)
    } else {
      kept.push(ended)
    }
  }
  if kept.length() != self.ended.length() {
    self.ended.clear()
    self.ended.push_iter(kept.iter())
  }
}

///|
async fn Listener::receive(
  self : Listener,
  group : @async.TaskGroup,
  quic : @h3.ServerQuic,
  bound_address : String,
  datagram : Bytes,
  peer : @socket.Addr,
) -> Unit {
  // A datagram without a connection ID to read is no QUIC packet.
  guard @h3.destination_cid(datagram) is Some(dcid) else { return }
  match self.routes.get(dcid) {
    Some(Live(conn)) => {
      conn.quic.read(datagram, from=peer.to_string()) catch {
        _ => ()
      }
      conn.follow()
      self.dispatch(group, conn)
      conn.send()
    }
    Some(Ended(ended)) =>
      if ended.close is Some(close) && peer.to_string() == ended.peer {
        ended.received += 1
        if (ended.received & (ended.received - 1)) == 0 {
          self.udp.send(close, peer) catch {
            _ => ()
          }
        }
      }
    None => self.accept(group, quic, bound_address, datagram, dcid, peer)
  }
}

///|
/// A datagram for no connection: a client's Initial starts one; a short
/// header packet gets a Stateless Reset; anything else is dropped, as RFC
/// 9000 allows.
async fn Listener::accept(
  self : Listener,
  group : @async.TaskGroup,
  quic : @h3.ServerQuic,
  bound_address : String,
  datagram : Bytes,
  dcid : Bytes,
  peer : @socket.Addr,
) -> Unit {
  if (datagram[0].to_int() & 0x80) == 0 {
    let now = self.clock.now_unix_ms()
    if now - self.resets_since >= 1000L {
      self.resets_since = now
      self.resets = 0
    }
    if self.resets < RESETS_PER_SECOND &&
      @h3.stateless_reset(datagram, keys=self.keys) is Some(reset) {
      self.resets += 1
      self.udp.send(reset, peer) catch {
        _ => ()
      }
    }
    return
  }
  // A version this server does not speak: the client hears which it
  // does, and may try again with one, instead of waiting out its
  // handshake timeout. The answer is smaller than the datagram, and no
  // state is kept.
  if @h3.version_negotiation(datagram) is Some(packet) {
    self.udp.send(packet, peer) catch {
      _ => ()
    }
    return
  }
  if self.stopping || self.conns.length() >= self.limits.max_connections {
    return
  }
  let key = peer.to_string()
  // Initials from forged addresses would each hold a connection until its
  // handshake timed out; once many handshakes are open, a client first
  // proves it receives at its address.
  let mut open = 0
  for _, conn in self.conns {
    if !conn.quic.handshake_done() && !conn.quic.closed() {
      open += 1
    }
  }
  let validate = open >= (self.limits.max_connections / 4).max(1)
  if @h3.answer_initial(datagram, remote_address=key, validate~, keys=self.keys)
    is Some(answer) {
    self.udp.send(answer, peer) catch {
      _ => ()
    }
    return
  }
  let connection = @h3.QuicConn::server(
    quic,
    datagram,
    local_address=bound_address,
    remote_address=key,
    settings=self.settings,
    keys=self.keys,
  ) catch {
    // Not a client's Initial: dropped.
    _ => return
  }
  let conn = {
    peer,
    peer_text: key,
    udp: self.udp,
    quic: connection,
    ids: [dcid],
    routes: self.routes,
    streams: Map([]),
    handlers: 0,
    changes: self.changes,
    idle_since: self.clock.now_unix_ms(),
  }
  self.conns[self.next_id] = conn
  self.next_id += 1
  self.routes[dcid] = Live(conn)
  conn.quic.read(datagram) catch {
    _ => ()
  }
  self.dispatch(group, conn)
  conn.send()
}

///|
fn Listener::dispatch(
  self : Listener,
  group : @async.TaskGroup,
  conn : Served,
) -> Unit {
  for event in conn.quic.events() {
    match event {
      Headers(stream~, fields~, end_stream~) =>
        match conn.streams.get(stream) {
          // A section after the head: the trailers.
          Some(entry) => entry.stream.trailers_arrived(fields, ended=end_stream)
          // As HTTP/2's server: at the cap a new request is refused, so a
          // client that opens and resets streams cannot pile up tasks.
          None if conn.handlers >= self.settings.max_streams_bidi =>
            conn.quic.reset(stream, @h3.H3_REQUEST_REJECTED)
          None => {
            let s = @mux.ServerStream::new(stream, ended=end_stream)
            let entry = { stream: s, task: None, }
            conn.streams[stream] = entry
            conn.handlers += 1
            let context : @mux.ServerContext = {
              conn,
              changes: self.changes,
              handler: self.handler,
              limits: self.limits,
              scheme: "https",
              protocol: "h3",
              auto_date: self.auto_date,
              peer: Some(conn.peer_text),
              clock: self.clock,
              timer: self.timer,
              on_error: self.on_error,
              background: None,
              stopping: () => self.stopping,
              coordination: self.coordination,
            }
            let task = group.spawn(allow_failure=true, () => {
              defer {
                conn.handlers -= 1
                if conn.handlers == 0 {
                  conn.idle_since = self.clock.now_unix_ms()
                }
                conn.streams.remove(stream)
                // What the handler left unread gives the windows back:
                // `consume` opens the connection's window with the
                // stream's, and the bytes would otherwise hold the
                // connection's window shut for every later request.
                let left = s.body.fold(init=0, (n, b) => n + b.length())
                if left > 0 {
                  conn.quic.consume(stream, left)
                  s.body.clear()
                }
                self.changes.notify()
              }
              context.serve(s, fields)
            })
            entry.task = Some(task)
          }
        }
      Data(stream~, data) =>
        match conn.streams.get(stream) {
          Some(entry) =>
            if !entry.stream.arrived(data, self.limits.max_body_bytes) {
              conn.quic.consume(stream, data.length())
            }
          None => conn.quic.consume(stream, data.length())
        }
      EndStream(stream~) =>
        if conn.streams.get(stream) is Some(entry) {
          entry.stream.ended = true
        }
      Closed(stream~, code~) =>
        if conn.streams.get(stream) is Some(entry) {
          entry.stream.closed = true
          // Closed before its response was all sent, by any reset,
          // H3_NO_ERROR included: the handler is not waited for, as over
          // HTTP/2.
          if entry.task is Some(task) &&
            (code != @h3.H3_NO_ERROR || !entry.stream.sent_end) {
            task.cancel()
          }
        }
      Sent(stream~, end_stream~) =>
        if conn.streams.get(stream) is Some(entry) {
          entry.stream.sent += 1
          if end_stream {
            entry.stream.sent_end = true
          }
        }
      GoAway(..) | Drained(..) | TooLarge(..) | HandshakeDone => ()
      ConnectionClosed(..) =>
        for _, entry in conn.streams {
          if entry.task is Some(task) {
            task.cancel()
          }
        }
      @h3.H3Event::.. => ()
    }
  }
  self.changes.notify()
}

///|
/// Starts the stop: no new connection, and every connection hears the
/// GOAWAY notice. The listener sends the last GOAWAY a round trip later.
async fn Listener::stop(self : Listener) -> Unit noraise {
  self.stopping = true
  self.going = 1
  self.notice_at = self.clock.now_unix_ms()
  for _, conn in self.conns {
    conn.quic.shutdown(notice=true) catch {
      _ => ()
    }
    conn.send()
  }
  // Streams marked close_on_shutdown end now.
  self.changes.notify()
}

///|
/// The drain time is out: every handler is cancelled and every connection
/// closed with H3_NO_ERROR; the listener frees them as their handlers end.
async fn Listener::expire(self : Listener) -> Unit noraise {
  for _, conn in self.conns {
    for _, entry in conn.streams {
      if entry.task is Some(task) {
        task.cancel()
      }
    }
    if !conn.quic.closed() {
      conn.quic.close()
      conn.send()
    }
  }
  self.changes.notify()
}

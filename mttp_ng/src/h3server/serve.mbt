// An HTTP/3 server on one UDP socket: datagrams are routed to their
// connection by the client's address (the server disables migration), new
// connections start from a client's Initial, and a task per request stream
// runs the handler and writes its response through `@mux.ServerContext`,
// the stream code HTTP/2's server shares.

///|
/// A request stream and the task that serves it.
priv struct Entry {
  stream : @mux.ServerStream
  mut task : @async.Task[Unit]?
}

///|
/// One connection.
priv struct Served {
  peer : @socket.Addr
  udp : @socket.UdpServer
  quic : @h3.QuicConn
  streams : Map[Int64, Entry]
  /// Handlers running, cancelled ones still finishing included.
  mut handlers : Int32
  changes : @mux.Changes
}

///|
/// Sends what the connection has to say.
async fn Served::send(self : Served) -> Unit noraise {
  let datagrams = self.quic.datagrams() catch { _ => [] }
  for datagram in datagrams {
    self.udp.send(datagram, self.peer) catch {
      _ => ()
    }
  }
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
  conns : Map[String, Served]
  changes : @mux.Changes
  timer : &@rt.Timer
  clock : &@rt.Clock
  limits : @h1server.ServerLimits
  settings : @h3.H3Settings
  handler : @mttp_core.Handler
  auto_date : Bool
  on_error : (@mttp_core.TransportError) -> Unit
}

///|
/// Serves `handler` over HTTP/3 on UDP `addr` (`host:port`), with `quic`'s
/// certificate, until cancelled; then every connection is closed with
/// H3_NO_ERROR. `limits` applies as it does to HTTP/2 (`serve_h2_conn`):
/// the body bound, the timeouts, the header bound and `max_connections`
/// (more clients' Initials are dropped). `settings` gives the streams and
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
  let listener = {
    udp,
    conns: Map([]),
    changes: @mux.Changes::new(
      @runtime.RuntimeCoordination::new(),
      clock,
      timer,
    ),
    timer,
    clock,
    limits,
    settings: { ..settings, max_header_list: limits.max_header_bytes, },
    handler,
    auto_date,
    on_error,
  }
  @async.with_task_group(group => {
    // Stopped: every client hears the close at once.
    defer (for _, conn in listener.conns {
      conn.quic.close()
      let datagrams = conn.quic.datagrams() catch { _ => [] }
      for datagram in datagrams {
        @async.protect_from_cancel(() => {
          udp.send(datagram, conn.peer) catch {
            _ => ()
          }
        })
      }
      conn.quic.free()
    })
    listener.run(group, quic, bound_address)
  }) catch {
    error =>
      raise @server.ListenError::Accept(
        detail="HTTP/3 listener failed: \{error}",
      )
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
  while true {
    // The nearest timer of any connection bounds the wait.
    let mut wait = 1000
    for _, conn in self.conns {
      if conn.quic.expiry_ms() is Some(ms) && ms < wait {
        wait = ms
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
    for key, conn in self.conns {
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
        conn.quic.free()
      }
      self.conns.remove(key)
    }
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
  let key = peer.to_string()
  let conn = match self.conns.get(key) {
    Some(conn) => conn
    None => {
      if self.conns.length() >= self.limits.max_connections {
        return
      }
      let connection = @h3.QuicConn::server(
        quic,
        datagram,
        local_address=bound_address,
        remote_address=key,
        settings=self.settings,
      ) catch {
        // Not a client's Initial: dropped, as RFC 9000 allows.
        _ => return
      }
      let conn = {
        peer,
        udp: self.udp,
        quic: connection,
        streams: Map([]),
        handlers: 0,
        changes: self.changes,
      }
      self.conns[key] = conn
      conn
    }
  }
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
          // Trailers: only their end counts.
          Some(entry) => if end_stream { entry.stream.ended = true }
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
              peer: Some(conn.peer.to_string()),
              clock: self.clock,
              timer: self.timer,
              on_error: self.on_error,
              background: None,
            }
            let task = group.spawn(allow_failure=true, () => {
              defer {
                conn.handlers -= 1
                conn.streams.remove(stream)
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
          if code != @h3.H3_NO_ERROR && entry.task is Some(task) {
            task.cancel()
          }
        }
      Sent(stream~, end_stream=true) =>
        if conn.streams.get(stream) is Some(entry) {
          entry.stream.sent_end = true
        }
      Sent(..) | GoAway(..) | Drained(..) | TooLarge(..) | HandshakeDone => ()
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

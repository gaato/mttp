// An HTTP/3 server on one UDP socket: datagrams are routed to their
// connection by the client's address (the server disables migration), new
// connections start from a client's Initial, and a task per request stream
// runs the handler and writes its response. ServerLimits applies as h2server
// applies it.

///|
/// One request stream.
priv struct ServerStream {
  id : Int64
  body : Array[Bytes]
  mut received : Int64
  mut ended : Bool
  mut closed : Int64?
  mut failure : @mttp_core.TransportError?
  mut task : @async.Task[Unit]?
}

///|
/// One connection.
priv struct Served {
  peer : @socket.Addr
  quic : @h3.QuicConn
  streams : Map[Int64, ServerStream]
  mut handlers : Int32
}

///|
/// The listener's state.
priv struct Listener {
  udp : @socket.UdpServer
  conns : Map[String, Served]
  changed : @cond_var.Cond
  timer : &@rt.Timer
  clock : &@rt.Clock
  limits : @h1server.ServerLimits
  settings : @h3.H3Settings
  handler : @mttp_core.Handler
  auto_date : Bool
  on_error : (@mttp_core.TransportError) -> Unit
}

///|
/// Sends what `conn` has to say.
async fn Listener::flush(self : Listener, conn : Served) -> Unit noraise {
  let datagrams = conn.quic.datagrams() catch { _ => [] }
  for datagram in datagrams {
    self.udp.send(datagram, conn.peer) catch {
      _ => ()
    }
  }
}

///|
/// Serves `handler` over HTTP/3 on UDP `addr` (`host:port`), with `quic`'s
/// certificate, until cancelled; then every connection is closed with
/// H3_NO_ERROR. `limits` applies as it does to HTTP/2 (`serve_h2_conn`):
/// the body bound, the timeouts, the header bound and `max_connections`
/// (more clients' Initials are dropped). `settings` gives the streams and
/// windows. Requests carry the `protocol` attribute `h3` and
/// `connection_scheme` `https`. `on_listen` hears the bound address.
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
  let listener = {
    udp,
    conns: Map([]),
    changed: @cond_var.Cond(),
    timer: @runtime.ClockTimer::new(clock~),
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
        self.flush(conn)
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
      let conn = { peer, quic: connection, streams: Map([]), handlers: 0, }
      self.conns[key] = conn
      conn
    }
  }
  conn.quic.read(datagram) catch {
    _ => ()
  }
  self.dispatch(group, conn)
  self.flush(conn)
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
          Some(s) => if end_stream { s.ended = true }
          None => {
            let s = {
              id: stream,
              body: [],
              received: 0L,
              ended: end_stream,
              closed: None,
              failure: None,
              task: None,
            }
            conn.streams[stream] = s
            conn.handlers += 1
            let task = group.spawn(allow_failure=true, () => {
              defer {
                conn.handlers -= 1
                conn.streams.remove(stream)
                self.changed.broadcast()
              }
              self.serve_stream(conn, s, fields)
            })
            s.task = Some(task)
          }
        }
      Data(stream~, data) =>
        match conn.streams.get(stream) {
          Some(s) => {
            s.received += data.length().to_int64()
            if s.received > self.limits.max_body_bytes.to_int64() {
              let limit = self.limits.max_body_bytes
              conn.quic.consume(stream, data.length())
              if s.failure is None {
                s.failure = Some(
                  @mttp_core.TransportError(
                    kind=TooLarge(limit~),
                    phase=Body,
                    detail="the request body is larger than \{limit} bytes",
                  ),
                )
              }
            } else {
              s.body.push(data)
            }
          }
          None => conn.quic.consume(stream, data.length())
        }
      EndStream(stream~) =>
        if conn.streams.get(stream) is Some(s) {
          s.ended = true
        }
      Closed(stream~, code~) =>
        if conn.streams.get(stream) is Some(s) {
          s.closed = Some(code)
          if code != @h3.H3_NO_ERROR && s.task is Some(task) {
            task.cancel()
          }
        }
      Sent(..) | GoAway(..) | Drained(..) | TooLarge(..) | HandshakeDone => ()
      ConnectionClosed(..) =>
        for _, s in conn.streams {
          if s.task is Some(task) {
            task.cancel()
          }
        }
      @h3.H3Event::.. => ()
    }
  }
  self.changed.broadcast()
}

///|
async fn Listener::wait(self : Listener, ms : Int32) -> Bool noraise {
  self.timer.within(ms, () => self.changed.wait())
}

///|
/// A request body read from its stream's buffer.
priv struct RequestBody {
  listener : Listener
  conn : Served
  stream : ServerStream
  mut done : Bool
}

///|
impl @mttp_core.BodyStream for RequestBody with fn read_some(self) {
  let stream = self.stream
  while !self.done {
    if stream.failure is Some(error) {
      raise error
    }
    if stream.body.length() > 0 {
      let bytes = stream.body.remove(0)
      self.conn.quic.consume(stream.id, bytes.length())
      self.listener.flush(self.conn)
      return Some(bytes)
    }
    if stream.ended {
      self.done = true
      return None
    }
    if stream.closed is Some(_) || self.conn.quic.closed() {
      raise @mttp_core.TransportError(
        kind=Network,
        phase=Body,
        detail="the client reset the stream before its body ended",
      )
    }
    let ms = self.listener.limits.body_timeout_ms
    if !self.listener.wait(ms) {
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
let connection_fields : Array[String] = [
  "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade",
]

///|
fn body_status(error : @mttp_core.TransportError) -> Int32 {
  match error {
    @mttp_core.TransportError(kind=TooLarge(..), ..) => 413
    @mttp_core.TransportError(kind=Timeout(..), ..) => 408
    _ => 400
  }
}

///|
/// Runs the handler of one stream and writes its response.
async fn Listener::serve_stream(
  self : Listener,
  conn : Served,
  stream : ServerStream,
  fields : Array[(String, String)],
) -> Unit {
  let request = match self.request(conn, stream, fields) {
    Ok(request) => request
    Err(status) => {
      self.respond(conn, stream, @mttp_core.Response::new(status), head=false)
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
  self.respond(conn, stream, response, head=request.meth is Head)
}

///|
fn Listener::request(
  self : Listener,
  conn : Served,
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
        RequestBody::{ listener: self, conn, stream, done: false, },
        length?=if length >= 0L { Some(length) } else { None },
      ),
    )
  }
  let attributes = @mttp_core.Attributes::empty()
    .put(@mttp_core.protocol, "h3")
    .put(@mttp_core.connection_scheme, "https")
    .put(@mttp_core.remote_addr, conn.peer.to_string())
  Ok({
    ..@mttp_core.Request::new(
      @mttp_core.Method::parse(meth),
      "https://\{authority}\{path}",
    ),
    headers,
    body,
    attributes,
  })
}

///|
async fn Listener::respond(
  self : Listener,
  conn : Served,
  stream : ServerStream,
  response : @mttp_core.Response,
  head~ : Bool,
) -> Unit {
  let quic = conn.quic
  defer response.close()
  let response = if response.status == 101 || response.status < 200 {
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
  quic.submit_response(stream.id, fields, body=has_body) catch {
    _ => return
  }
  match response.body {
    Bytes(bytes) if has_body =>
      quic.push(stream.id, bytes, end=true) catch {
        _ => ()
      }
    Stream(cell) if has_body => {
      let source = cell.take() catch { _ => return }
      defer source.close()
      while true {
        self.flush(conn)
        while quic.queued(stream.id).unwrap_or(0) >= 65536 {
          if stream.closed is Some(_) || quic.closed() {
            return
          }
          if !self.wait(self.limits.body_timeout_ms) {
            quic.reset(stream.id, @h3.H3_INTERNAL_ERROR)
            self.flush(conn)
            return
          }
        }
        if stream.closed is Some(_) || quic.closed() {
          return
        }
        let piece = source.read_some() catch {
          _ => {
            quic.reset(stream.id, @h3.H3_INTERNAL_ERROR)
            self.flush(conn)
            return
          }
        }
        match piece {
          Some(bytes) =>
            quic.push(stream.id, bytes, end=false) catch {
              _ => return
            }
          None => {
            quic.push(stream.id, b"", end=true) catch {
              _ => ()
            }
            break
          }
        }
      }
    }
    _ => ()
  }
  self.flush(conn)
  // As HTTP/2 does: once the response went, a client still sending is told
  // to stop (STOP_SENDING with H3_NO_ERROR, RFC 9114, section 4.1).
  if !stream.ended && stream.closed is None {
    quic.reset(stream.id, @h3.H3_NO_ERROR, read_only=true)
    self.flush(conn)
  }
}

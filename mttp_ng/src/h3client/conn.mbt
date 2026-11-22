// One QUIC connection and the HTTP/3 streams on it, driven as h2client
// drives an HTTP/2 connection: whoever waits on it takes the reader's role.
// Here the reader also runs the connection's timers: it waits for a
// datagram no longer than until the next expiry, and handles the expiry
// when none came. A datagram send is never cut off midway and a lost one
// is sent again, so writes need no protection from cancellation.

///|
/// Where one request stream stands.
priv struct Stream {
  id : Int64
  mut head : (Int32, @mttp_core.Headers)?
  body : Array[Bytes]
  mut buffered : Int32
  mut ended : Bool
  /// The stream closed, with its HTTP/3 error code.
  mut closed : Int64?
  mut headers_sent : Bool
  mut sent_end : Bool
  mut too_large : Bool
  mut malformed : String?
}

///|
fn Stream::new(id : Int64) -> Stream {
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
  }
}

///|
priv struct Connection {
  udp : @socket.UdpClient
  quic : @h3.QuicConn
  coordination : &@rt.Coordination
  timer : &@rt.Timer
  clock : &@rt.Clock
  streams : Map[Int64, Stream]
  mut changed : &@rt.Signal
  mut reading : Bool
  mut writing : Bool
  mut dead : @mttp_core.TransportError?
  /// The server's GOAWAY: the first request stream it does not process.
  mut goaway : Int64?
  mut handshake : Bool
  mut active : Int32
  mut reserved : Int32
  opened_at : Int64
  mut idle_since : Int64
  /// When a datagram last arrived, for the idle timeout.
  mut heard_at : Int64
  mut retired : Bool
  mut closed : Bool
}

///|
fn Connection::new(
  udp : @socket.UdpClient,
  quic : @h3.QuicConn,
  coordination : &@rt.Coordination,
  timer : &@rt.Timer,
  clock : &@rt.Clock,
) -> Connection {
  let now = clock.now_unix_ms()
  {
    udp,
    quic,
    coordination,
    timer,
    clock,
    streams: Map([]),
    changed: coordination.signal(),
    reading: false,
    writing: false,
    dead: None,
    goaway: None,
    handshake: false,
    active: 0,
    reserved: 0,
    opened_at: now,
    idle_since: now,
    heard_at: now,
    retired: false,
    closed: false,
  }
}

///|
fn Connection::notify(self : Connection) -> Unit {
  let woken = self.changed
  self.changed = self.coordination.signal()
  woken.notify()
}

///|
fn Connection::fail(
  self : Connection,
  error : @mttp_core.TransportError,
) -> Unit {
  if self.dead is None {
    self.dead = Some(error)
  }
  self.retired = true
  self.notify()
}

///|
/// Closes the socket and frees the connection. The CONNECTION_CLOSE is not
/// sent, since closing cannot wait for a send: the server's idle timeout
/// ends its side.
fn Connection::close(self : Connection) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.fail(
    @mttp_core.TransportError(
      kind=Closed,
      phase=Unknown,
      detail="the HTTP/3 connection is closed",
    ),
  )
  self.udp.close()
  self.quic.free()
}

///|
fn Connection::usable(self : Connection) -> Bool {
  !self.retired &&
  !self.closed &&
  self.dead is None &&
  self.goaway is None &&
  !self.quic.closed() &&
  // Well before the idle timeout: a connection near it may be gone already.
  self.clock.now_unix_ms() - self.heard_at < self.quic.idle_ms() / 2L
}

///|
/// The streams a server allows at once are its transport parameter, which
/// ngtcp2 enforces when a stream opens; one waits for room there instead
/// (`submit_request` raises), so the count here only spreads sends.
fn Connection::has_room(self : Connection, limit : Int32) -> Bool {
  self.active + self.reserved < limit
}

///|
fn Connection::dispatch(self : Connection) -> Unit {
  for event in self.quic.events() {
    match event {
      HandshakeDone => self.handshake = true
      Headers(stream~, fields~, end_stream~) =>
        if self.streams.get(stream) is Some(s) {
          if s.head is None {
            match response_head(fields) {
              Ok(None) => ()
              Ok(Some(head)) => s.head = Some(head)
              Err(detail) => {
                s.malformed = Some(detail)
                self.quic.reset(stream, @h3.H3_REQUEST_CANCELLED)
              }
            }
          }
          if end_stream {
            s.ended = true
          }
        }
      Data(stream~, data) =>
        match self.streams.get(stream) {
          Some(s) => {
            s.body.push(data)
            s.buffered += data.length()
          }
          // A stream released before its end: its bytes count no more.
          None => self.quic.consume(stream, data.length())
        }
      EndStream(stream~) =>
        if self.streams.get(stream) is Some(s) {
          s.ended = true
        }
      Closed(stream~, code~) =>
        if self.streams.get(stream) is Some(s) {
          s.closed = Some(code)
        }
      GoAway(id~) => {
        self.goaway = Some(id)
        self.retired = true
      }
      Sent(stream~, end_stream~) =>
        if self.streams.get(stream) is Some(s) {
          s.headers_sent = true
          if end_stream {
            s.sent_end = true
          }
        }
      TooLarge(stream~) =>
        if self.streams.get(stream) is Some(s) {
          s.too_large = true
        }
      ConnectionClosed(code~, by_peer~) =>
        self.fail(
          @mttp_core.TransportError(
            kind=Network,
            phase=Unknown,
            detail=if by_peer {
              "the server closed the QUIC connection (\{code})"
            } else {
              "the QUIC connection closed (\{code})"
            },
          ),
        )
      Drained(..) => ()
      @h3.H3Event::.. => ()
    }
  }
}

///|
/// Sends what the connection has to say, one sender at a time.
async fn Connection::flush(
  self : Connection,
) -> Unit raise @mttp_core.TransportError {
  while self.writing {
    if self.dead is Some(error) {
      raise error
    }
    self.changed.wait()
  }
  self.writing = true
  defer {
    self.writing = false
    self.notify()
  }
  while true {
    let datagrams = self.quic.datagrams() catch {
      error => {
        self.dispatch()
        let failure = @mttp_core.TransportError(
          kind=Protocol,
          phase=Unknown,
          detail=error.to_string(),
        )
        self.fail(failure)
        raise failure
      }
    }
    self.dispatch()
    if datagrams.is_empty() {
      return
    }
    for datagram in datagrams {
      self.udp.send(datagram) catch {
        error => {
          let failure = @mttp_core.TransportError(
            kind=Network,
            phase=Unknown,
            detail="UDP send: \{error}",
          )
          self.fail(failure)
          raise failure
        }
      }
    }
  }
}

///|
async fn Connection::flush_if_idle(self : Connection) -> Unit noraise {
  if !self.writing && self.dead is None {
    self.flush() catch {
      @mttp_core.TransportError(..) => ()
    }
  }
}

///|
/// One turn of the reader: a datagram, or the expiry of the timers when
/// none came first; then the events and what there is to send. Given up as
/// soon as `done` holds after a change, as h2client's reader does.
async fn Connection::read_once(
  self : Connection,
  done : () -> Bool,
) -> Unit noraise {
  self.reading = true
  defer {
    self.reading = false
    self.notify()
  }
  let wait = self.quic.expiry_ms().unwrap_or(1000)
  let got : Ref[Bytes?] = Ref(None)
  let failure : Ref[String?] = Ref(None)
  let interrupted = Ref(false)
  if wait > 0 {
    self.coordination.supervise(
      primary=() => {
        ignore(
          self.timer.within(wait, () => {
            got.val = Some(self.udp.recv(max_len=65536)) catch {
              error => {
                failure.val = Some(error.to_string())
                None
              }
            }
          }),
        )
      },
      monitor=() => {
        while !done() {
          let signal = self.changed
          signal.wait()
        }
        interrupted.val = true
        raise @mttp_core.TransportError(
          kind=Closed,
          phase=Unknown,
          detail="the reader's wait is over",
        )
      },
    ) catch {
      @mttp_core.TransportError(..) => if interrupted.val { return }
    }
  }
  if failure.val is Some(detail) {
    // An ICMP error on the connected socket: nothing listens there.
    self.fail(
      @mttp_core.TransportError(
        kind=Connect,
        phase=Unknown,
        detail="UDP: \{detail}",
      ),
    )
    return
  }
  match got.val {
    Some(datagram) => {
      self.heard_at = self.clock.now_unix_ms()
      self.quic.read(datagram) catch {
        _ => ()
      }
    }
    None =>
      if self.quic.expiry_ms() == Some(0) {
        self.quic.on_expiry() catch {
          _ => ()
        }
      }
  }
  self.dispatch()
  self.flush_if_idle()
}

///|
async fn Connection::wait_until(
  self : Connection,
  done : () -> Bool,
) -> Unit raise @mttp_core.TransportError {
  while !done() {
    if self.dead is Some(error) {
      raise error
    }
    if self.reading {
      self.changed.wait()
    } else {
      self.read_once(done)
    }
  }
}

///|
fn Connection::release(self : Connection, stream : Stream) -> Unit {
  guard self.streams.get(stream.id) is Some(_) else { return }
  self.streams.remove(stream.id)
  self.active -= 1
  if !self.closed {
    // What was buffered and not read gives the window back.
    if stream.buffered > 0 {
      self.quic.consume(stream.id, stream.buffered)
    }
    if stream.closed is None {
      self.quic.reset(stream.id, @h3.H3_REQUEST_CANCELLED)
    }
  }
  if self.active == 0 {
    self.idle_since = self.clock.now_unix_ms()
  }
  self.notify()
}

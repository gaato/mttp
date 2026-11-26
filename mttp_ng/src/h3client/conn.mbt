// One QUIC connection and the HTTP/3 streams on it, driven as h2client
// drives an HTTP/2 connection: whoever waits on it takes the reader's role.
// Here the reader also runs the connection's timers: it waits for a
// datagram no longer than until the next expiry, and handles the expiry
// when none came. A datagram send is never cut off midway and a lost one
// is sent again, so writes need no protection from cancellation.

///|
/// A stream's request body queue holds at most this many bytes before the
/// uploader waits.
const QUEUE_BYTES : Int32 = 65536

///|
priv struct Connection {
  udp : @socket.UdpClient
  quic : @h3.QuicConn
  coordination : &@rt.Coordination
  timer : &@rt.Timer
  clock : &@rt.Clock
  streams : Map[Int64, @mux.ClientStream]
  changes : @mux.Changes
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
    changes: @mux.Changes::new(coordination, clock, timer),
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
  self.changes.notify()
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
/// How long the CONNECTION_CLOSE of a connection this end drops may take
/// to go: a datagram send seldom waits at all.
const CLOSE_SEND_MS : Int32 = 100

///|
/// Tells the server the connection is done (CONNECTION_CLOSE with
/// H3_NO_ERROR, RFC 9000, section 10.2), so that its side ends now rather
/// than at its idle timeout, then closes it. The send is bounded and runs
/// even when the caller is cancelled.
async fn Connection::close_gracefully(self : Connection) -> Unit noraise {
  if self.closed {
    return
  }
  if !self.quic.closed() {
    self.quic.close()
    let datagrams = self.quic.datagrams() catch { _ => [] }
    self.coordination.protect(work=() => {
      ignore(
        self.timer.within(CLOSE_SEND_MS, () => {
          for datagram in datagrams {
            self.udp.send(datagram) catch {
              _ => ()
            }
          }
        }),
      )
    }) catch {
      _ => ()
    }
  }
  self.close()
}

///|
/// Closes the socket and frees the connection, sending nothing: for a
/// caller that cannot wait for a send (`close_gracefully` sends the
/// CONNECTION_CLOSE first).
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
/// Whether another stream fits: under `limit` streams at once, and under
/// the server's MAX_STREAMS, which counts the streams it lets the client
/// open over the connection's life and grows as streams close (RFC 9000,
/// section 4.6). A send waits for room in phase Pool rather than open a
/// stream ngtcp2 would refuse (STREAM_ID_BLOCKED), which retires the
/// connection.
fn Connection::has_room(self : Connection, limit : Int32) -> Bool {
  self.active + self.reserved < limit &&
  self.reserved.to_int64() < self.quic.streams_left()
}

///|
fn Connection::dispatch(self : Connection) -> Unit {
  for event in self.quic.events() {
    match event {
      HandshakeDone => self.handshake = true
      Headers(stream~, fields~, end_stream~) =>
        if self.streams.get(stream) is Some(s) {
          if s.head_arrived(fields) {
            self.quic.reset(stream, @h3.H3_MESSAGE_ERROR)
          }
          if end_stream {
            s.ended = true
          }
        }
      Data(stream~, data) =>
        match self.streams.get(stream) {
          Some(s) => s.data_arrived(data)
          // A stream released before its end: its bytes count no more.
          None => self.quic.consume(stream, data.length())
        }
      EndStream(stream~) =>
        if self.streams.get(stream) is Some(s) {
          s.ended = true
        }
      Closed(stream~, code~) =>
        if self.streams.get(stream) is Some(s) {
          s.closed = Some(stream_end(code))
        }
      GoAway(id~) => {
        self.goaway = Some(id)
        self.retired = true
        // A request stream from `id` up was not processed (RFC 9114,
        // section 5.2), and the server need not reset it: it is closed
        // here, so that whatever waits on it (a head, an upload, a body)
        // sees `Refused` now rather than at its deadline, and its stream
        // is given up. nghttp2 closes HTTP/2's such streams itself.
        for _, s in self.streams {
          if s.id >= id && s.head is None && s.closed is None {
            s.closed = Some(
              Refused("the server's GOAWAY left stream \{s.id} unprocessed"),
            )
            self.quic.reset(s.id, @h3.H3_REQUEST_CANCELLED)
          }
        }
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
async fn Connection::send_output(
  self : Connection,
) -> Unit raise @mttp_core.TransportError {
  while self.writing {
    if self.dead is Some(error) {
      raise error
    }
    self.changes.next().wait()
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
async fn Connection::send_if_idle(self : Connection) -> Unit noraise {
  if !self.writing && self.dead is None {
    self.send_output() catch {
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
        ignore(self.changes.wait_until(done))
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
  self.send_if_idle()
}

///|
async fn Connection::wait_for(
  self : Connection,
  done : () -> Bool,
) -> Unit raise @mttp_core.TransportError {
  while !done() {
    if self.dead is Some(error) {
      raise error
    }
    if self.reading {
      self.changes.next().wait()
    } else {
      self.read_once(done)
    }
  }
}

///|
/// How a stream that closed with HTTP/3 error `code` ended.
fn stream_end(code : Int64) -> @mux.StreamEnd {
  if code == @h3.H3_NO_ERROR {
    Clean
  } else if code == @h3.H3_REQUEST_REJECTED {
    Refused("the server rejected the request (H3_REQUEST_REJECTED)")
  } else {
    Failed(protocol=code == @h3.H3_MESSAGE_ERROR, "HTTP/3 error \{code}")
  }
}

///|
/// What an exchange of `@mux.exchange` needs of an HTTP/3 connection.
impl @mux.ClientConn for Connection with fn open_stream(self, fields, body~) {
  let id = self.quic.submit_request(fields, body~) catch {
    error => {
      self.retired = true
      self.notify()
      raise @mttp_core.TransportError(
        kind=Refused,
        phase=Pool,
        detail="the connection took no new stream: \{error}",
      )
    }
  }
  let stream = @mux.ClientStream::new(id)
  self.streams[id] = stream
  self.active += 1
  stream
}

///|
impl @mux.ClientConn for Connection with fn push(self, stream, data, end~) {
  try {
    self.quic.push(stream.id, data, end~)
    true
  } catch {
    _ => false
  }
}

///|
impl @mux.ClientConn for Connection with fn end_with_trailers(
  self,
  stream,
  fields,
) {
  try {
    self.quic.end_with_trailers(stream.id, fields)
    true
  } catch {
    _ => false
  }
}

///|
impl @mux.ClientConn for Connection with fn queued(self, stream) {
  self.quic.queued(stream.id).unwrap_or(0)
}

///|
impl @mux.ClientConn for Connection with fn consume(self, stream, len) {
  self.quic.consume(stream.id, len)
}

///|
/// Ends `stream` on this end's side: what it buffered and nobody read
/// gives the windows back, and a stream still open is reset with
/// H3_REQUEST_CANCELLED.
impl @mux.ClientConn for Connection with fn release(self, stream) {
  guard self.streams.get(stream.id) is Some(_) else { return }
  self.streams.remove(stream.id)
  self.active -= 1
  if !self.closed {
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

///|
impl @mux.ClientConn for Connection with fn flush(self) {
  self.send_output()
}

///|
impl @mux.ClientConn for Connection with fn flush_if_idle(self) {
  self.send_if_idle()
}

///|
impl @mux.ClientConn for Connection with fn wait_until(self, done) {
  self.wait_for(done)
}

///|
impl @mux.ClientConn for Connection with fn dead(self) {
  self.dead
}

///|
/// A server's GOAWAY names the first request stream it does not process
/// (RFC 9114, section 5.2).
impl @mux.ClientConn for Connection with fn beyond_goaway(self, stream) {
  self.goaway is Some(first) && stream.id >= first
}

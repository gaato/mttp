// One HTTP/2 connection and the streams on it.
//
// No task belongs to the connection. Whoever waits for something on it (a
// response head, body bytes, room in a body queue, a free stream) takes the
// reader's role when nobody holds it: one read from the connection, the
// session's events handed to their streams, and the session's output written.
// The others wait for the connection's `changed` signal, which every step
// rings, and look again; one of them takes the role when its holder lets it
// go. So the connection is read as long as anyone waits on it, and nothing
// outlives the sends and bodies that use it.
//
// Writes run inside `Coordination::protect`, with a deadline of their own: a
// write cut off midway would leave half a frame on a connection other
// streams share, so a cancelled send waits for its write to end instead.

///|
/// How long one write to the connection may take. It runs protected from
/// cancellation, so this bounds how long a cancelled send can wait for it.
const WRITE_MS : Int32 = 10000

///|
/// The most one read takes from the connection.
const READ_BYTES : Int32 = 65536

///|
/// A stream's request body queue holds at most this many bytes before the
/// uploader waits.
const QUEUE_BYTES : Int32 = 65536

///|
/// Where one stream stands, as the connection's events left it.
priv struct Stream {
  id : Int32
  /// The final response: its status and fields.
  mut head : (Int32, @mttp_core.Headers)?
  /// Body bytes not yet taken by the reader, and how many.
  body : Array[Bytes]
  mut buffered : Int32
  /// The peer ended its half.
  mut ended : Bool
  /// The stream closed, with the code (NoError when both halves ended).
  mut closed : @h2.ErrorCode?
  /// HEADERS of this stream were serialized for sending: from here the
  /// request may have reached the peer.
  mut headers_sent : Bool
  /// The whole request went out.
  mut sent_end : Bool
  /// The response head was larger than the limit.
  mut too_large : Bool
  /// The response head is not a valid HTTP/2 response.
  mut malformed : String?
}

///|
fn Stream::new(id : Int32) -> Stream {
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
/// An HTTP/2 connection over `conn`.
priv struct Connection {
  conn : &@rt.Conn
  session : @h2.H2Session
  coordination : &@rt.Coordination
  timer : &@rt.Timer
  clock : &@rt.Clock
  streams : Map[Int32, Stream]
  /// Rung and replaced after every step and whenever a role is let go.
  mut changed : &@rt.Signal
  mut reading : Bool
  mut writing : Bool
  /// Why the connection can carry nothing more.
  mut dead : @mttp_core.TransportError?
  /// The peer's GOAWAY: streams above this one were not processed.
  mut goaway : Int32?
  /// The peer's first SETTINGS arrived. Until then one stream goes on the
  /// connection: nghttp2 assumes a limit of 100, and a server with a lower
  /// one would refuse the streams above it.
  mut settled : Bool
  /// Streams opened and not yet released.
  mut active : Int32
  /// Streams reserved by sends about to open one.
  mut reserved : Int32
  opened_at : Int64
  mut idle_since : Int64
  /// No new stream goes on this connection (age, GOAWAY, failure).
  mut retired : Bool
  mut closed : Bool
}

///|
fn Connection::new(
  conn : &@rt.Conn,
  session : @h2.H2Session,
  coordination : &@rt.Coordination,
  timer : &@rt.Timer,
  clock : &@rt.Clock,
) -> Connection {
  let now = clock.now_unix_ms()
  {
    conn,
    session,
    coordination,
    timer,
    clock,
    streams: Map([]),
    changed: coordination.signal(),
    reading: false,
    writing: false,
    dead: None,
    goaway: None,
    settled: false,
    active: 0,
    reserved: 0,
    opened_at: now,
    idle_since: now,
    retired: false,
    closed: false,
  }
}

///|
/// Wakes everyone waiting on the connection.
fn Connection::notify(self : Connection) -> Unit {
  let woken = self.changed
  self.changed = self.coordination.signal()
  woken.notify()
}

///|
/// Marks the connection unusable with `error`, unless it already was.
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
/// Closes the connection beneath and frees the session. Waiters see
/// `Closed`.
fn Connection::close(self : Connection) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.fail(
    @mttp_core.TransportError(
      kind=Closed,
      phase=Unknown,
      detail="the HTTP/2 connection is closed",
    ),
  )
  self.conn.close()
  self.session.free()
}

///|
/// Whether a new stream may go on this connection.
fn Connection::usable(self : Connection) -> Bool {
  !self.retired &&
  !self.closed &&
  self.dead is None &&
  self.goaway is None &&
  self.session.can_open()
}

///|
/// Whether another stream fits under the peer's limit.
fn Connection::has_room(self : Connection) -> Bool {
  let limit = if self.settled { self.session.peer_max_streams() } else { 1 }
  self.active + self.reserved < limit
}

///|
/// Hands the session's events to their streams.
fn Connection::dispatch(self : Connection, events : Array[@h2.H2Event]) -> Unit {
  for event in events {
    match event {
      Headers(stream~, kind~, fields~, end_stream~) =>
        if self.streams.get(stream) is Some(s) {
          match kind {
            Response | Trailers if s.head is None =>
              match response_head(fields) {
                // An interim response: the final one follows.
                Ok(None) => ()
                Ok(Some(head)) => s.head = Some(head)
                Err(detail) => {
                  s.malformed = Some(detail)
                  self.session.reset(stream, ProtocolError) catch {
                    _ => ()
                  }
                }
              }
            // Trailer fields are not passed on (nobody asks; CONTRACT.md).
            _ => ()
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
            // The connection's window opens as soon as the bytes are in
            // the stream's buffer, which its own window bounds.
            self.session.consume_connection(data.length())
          }
          None => self.session.consume_connection(data.length())
        }
      EndStream(stream~) =>
        if self.streams.get(stream) is Some(s) {
          s.ended = true
        }
      Closed(stream~, code~) =>
        if self.streams.get(stream) is Some(s) {
          s.closed = Some(code)
        }
      GoAway(last_stream~, ..) => {
        self.goaway = Some(last_stream)
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
      NotSent(stream~, ..) =>
        if self.streams.get(stream) is Some(s) && s.closed is None {
          s.closed = Some(RefusedStream)
        }
      Settings(..) => self.settled = true
      Drained(..) | PingAck => ()
      @h2.H2Event::.. => ()
    }
  }
}

///|
/// Takes the reader's role for one read: the bytes go to the session, its
/// events to the streams, and its output out. The read is given up as soon
/// as `done` holds after a change on the connection, since what the reader
/// waits for may come from another task (a stream released, a body queue
/// drained) while the server has nothing to send.
async fn Connection::read_once(
  self : Connection,
  done : () -> Bool,
) -> Unit noraise {
  self.reading = true
  defer {
    self.reading = false
    self.notify()
  }
  let chunk : Ref[Bytes?] = Ref(None)
  let interrupted = Ref(false)
  self.coordination.supervise(
    primary=() => chunk.val = self.conn.read(max_len=READ_BYTES),
    monitor=() => {
      // Looked at before every wait: a change between the start of the read
      // and the first wait rang a signal this monitor never waited on.
      while !done() {
        let signal = self.changed
        signal.wait()
      }
      interrupted.val = true
      // Cancels the read, which gives up nothing (rt.Conn).
      raise @mttp_core.TransportError(
        kind=Closed,
        phase=Unknown,
        detail="the reader's wait is over",
      )
    },
  ) catch {
    @mttp_core.TransportError(..) as error => {
      if !interrupted.val {
        self.fail(with_phase(error, Unknown))
      }
      return
    }
  }
  match chunk.val {
    None => {
      self.dispatch(self.session.events())
      self.fail(
        @mttp_core.TransportError(
          kind=Network,
          phase=Unknown,
          detail="the server closed the HTTP/2 connection",
        ),
      )
    }
    Some(bytes) => {
      let failed = try {
        self.session.recv(bytes)
        None
      } catch {
        @h2.H2Error(..) as error => Some(error)
      }
      self.dispatch(self.session.events())
      match failed {
        // A fatal protocol error: nghttp2 queued GOAWAY, which goes out
        // below as far as the connection lets it.
        Some(error) => {
          self.flush() catch {
            @mttp_core.TransportError(..) => ()
          }
          self.fail(
            @mttp_core.TransportError(
              kind=Protocol,
              phase=Unknown,
              detail=error.to_string(),
            ),
          )
        }
        None => self.flush_if_idle()
      }
    }
  }
}

///|
/// Writes the session's output, one writer at a time; a writer that finds
/// another at work waits for it and writes what is left. Each write is
/// protected from cancellation and bounded by `WRITE_MS`.
async fn Connection::flush(
  self : Connection,
) -> Unit raise @mttp_core.TransportError {
  while self.writing {
    if self.dead is Some(error) {
      raise error
    }
    self.changed.wait()
  }
  if self.dead is Some(error) {
    raise error
  }
  self.writing = true
  defer {
    self.writing = false
    self.notify()
  }
  while self.dead is None {
    let output = self.session.output()
    if output.length() == 0 {
      break
    }
    // Events the serialization caused (a frame sent or not sent).
    self.dispatch(self.session.events())
    let failure : Ref[@mttp_core.TransportError?] = Ref(None)
    self.coordination.protect(work=() => {
      let finished = self.timer.within(WRITE_MS, () => {
        self.conn.write(output) catch {
          @mttp_core.TransportError(..) as error => failure.val = Some(error)
        }
      })
      if !finished && failure.val is None {
        failure.val = Some(
          @mttp_core.TransportError(
            kind=Timeout(ms=WRITE_MS),
            phase=Unknown,
            detail="a write to the HTTP/2 connection took longer than \{WRITE_MS} ms",
          ),
        )
      }
    })
    if failure.val is Some(error) {
      self.fail(error)
      raise error
    }
  }
}

///|
/// Writes what the session has to say after a read (acknowledgements,
/// window updates), unless a writer is at work and will.
async fn Connection::flush_if_idle(self : Connection) -> Unit noraise {
  if !self.writing {
    self.flush() catch {
      @mttp_core.TransportError(..) => ()
    }
  }
}

///|
/// Waits until `done` holds, reading the connection meanwhile whenever no
/// one else does. Raises the connection's failure when it can carry nothing
/// more and `done` still does not hold.
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
/// Whether the peer is gone or has sent GOAWAY, found by reading what it
/// already sent without waiting for more. For a connection that sat idle.
async fn Connection::probe(self : Connection) -> Unit noraise {
  if self.reading || self.dead is Some(_) {
    return
  }
  ignore(self.timer.within(2, () => self.read_once(() => false)))
}

///|
/// Ends `stream` on this end's side: a stream still open is reset with
/// CANCEL, and its unread bytes are given back to the windows.
fn Connection::release(self : Connection, stream : Stream) -> Unit {
  guard self.streams.get(stream.id) is Some(_) else { return }
  self.streams.remove(stream.id)
  self.active -= 1
  if stream.closed is None && !self.closed {
    self.session.reset(stream.id, Cancel) catch {
      _ => ()
    }
  }
  if self.active == 0 {
    self.idle_since = self.clock.now_unix_ms()
  }
  self.notify()
}

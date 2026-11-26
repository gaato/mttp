// One HTTP/2 connection served: a reader that hands frames to the session,
// a writer that sends what the session has to say, and a task per stream
// that runs the handler and writes its response.

///|
/// The settings of HTTP/2 itself, beside `@h1server.ServerLimits` (which
/// gives the body bound, the timeouts and the header bound to HTTP/2 too).
/// Build them from `H2Limits::default()` with a record update.
#derive(Eq, Debug)
pub(all) struct H2Limits {
  /// SETTINGS_MAX_CONCURRENT_STREAMS, and the handlers that may run on one
  /// connection at once, cancelled ones still finishing included: while
  /// that many run, a new request stream is refused with REFUSED_STREAM
  /// (CVE-2023-44487), and the connection is still read for the others.
  max_concurrent_streams : Int32
  /// SETTINGS_INITIAL_WINDOW_SIZE: what one request body may send before
  /// its handler reads it.
  stream_window : Int32
  /// The connection's receive window over all request bodies.
  connection_window : Int32
}

///|
/// Compares limits.
pub extend H2Limits with Eq::{equal, not_equal}

///|
/// Formats limits for diagnostics.
pub extend H2Limits with @debug.Debug::{to_repr}

///|
/// 100 streams, 256 KiB per stream, 1 MiB per connection.
pub fn H2Limits::default() -> H2Limits {
  {
    max_concurrent_streams: 100,
    stream_window: 256 * 1024,
    connection_window: 1024 * 1024,
  }
}

///|
/// How long a closing connection's last input is read and dropped.
const LINGER_MS : Int32 = 100

///|
/// How often the reader looks at the stopping probe and the idle time.
const POLL_MS : Int32 = 250

///|
/// A request stream and the task that serves it.
priv struct Entry {
  stream : @mux.ServerStream
  mut task : @async.Task[Unit]?
}

///|
/// The state of a served connection.
priv struct Served {
  conn : &@rt.Conn
  session : @h2.H2Session
  timer : &@rt.Timer
  clock : &@rt.Clock
  limits : @h1server.ServerLimits
  h2_limits : H2Limits
  streams : Map[Int32, Entry]
  changes : @mux.Changes
  /// Handlers running, cancelled ones still finishing included.
  mut handlers : Int32
  /// The connection can carry nothing more.
  mut dead : Bool
}

///|
fn Served::wake(self : Served) -> Unit {
  self.changes.notify()
}

///|
/// What a stream of `@mux.ServerContext` needs of an HTTP/2 connection.
impl @mux.ServerConn for Served with fn submit_response(self, id, fields, body~) {
  let ok = try {
    self.session.submit_response(id.to_int(), fields, body~)
    true
  } catch {
    _ => false
  }
  self.wake()
  ok
}

///|
impl @mux.ServerConn for Served with fn send_continue(self, id) {
  let ok = try {
    self.session.submit_info(id.to_int(), [(":status", "100")])
    true
  } catch {
    _ => false
  }
  self.wake()
  ok
}

///|
impl @mux.ServerConn for Served with fn push(self, id, data, end~) {
  let ok = try {
    self.session.push(id.to_int(), data, end~)
    true
  } catch {
    _ => false
  }
  self.wake()
  ok
}

///|
impl @mux.ServerConn for Served with fn queued(self, id) {
  self.session.queued(id.to_int()).unwrap_or(0)
}

///|
impl @mux.ServerConn for Served with fn consume(self, id, len) {
  self.session.consume_stream(id.to_int(), len)
}

///|
impl @mux.ServerConn for Served with fn abort(self, id) {
  self.session.reset(id.to_int(), InternalError) catch {
    _ => ()
  }
  self.wake()
}

///|
/// RST_STREAM(NO_ERROR) once the response's last frame went out: a reset
/// drops what is still queued.
impl @mux.ServerConn for Served with fn stop_reading(self, stream) {
  ignore(
    self.changes.wait_until(
      () => stream.sent_end || stream.ended || stream.closed || self.dead,
      deadline=self.changes.deadline_in(self.limits.body_timeout_ms),
    ),
  )
  if !stream.ended && !stream.closed && !self.dead {
    self.session.reset(stream.id.to_int(), NoError) catch {
      _ => ()
    }
    self.wake()
  }
}

///|
impl @mux.ServerConn for Served with fn gone(self) {
  self.dead
}

///|
/// The writer task sends what the session has; a wake-up is enough.
impl @mux.ServerConn for Served with fn flush(self) {
  self.wake()
}

///|
/// Writes what the session has to say, the connection's only writer: two
/// writes at once would interleave their frames. Once the connection is
/// `dead`, it writes what is left (GOAWAY, the last frames of finished
/// streams) and ends, or ends at once when a write failed.
async fn Served::write_loop(self : Served) -> Unit noraise {
  while true {
    // Taken before the session is asked, so a change after the question
    // wakes the wait below.
    let next = self.changes.next()
    let output = self.session.output()
    // What serializing it caused: frames sent, streams closed.
    self.dispatch(None)
    if output.length() == 0 {
      if self.dead {
        return
      }
      next.wait()
      continue
    }
    // Bytes left the streams' queues: the tasks waiting on them look again.
    self.wake()
    let failed = Ref(false)
    let finished = self.timer.within(self.limits.body_timeout_ms, () => {
      self.conn.write(output) catch {
        @mttp_core.TransportError(..) => failed.val = true
      }
    })
    if failed.val || !finished {
      self.dead = true
      self.wake()
      return
    }
  }
}

///|
/// Serves HTTP/2 on `conn` until the client goes, the connection fails or
/// `stopping` turns true, when the client is told to go away (GOAWAY, first
/// a notice naming the highest stream, then the last one processed) and the
/// streams in flight finish. The connection's first bytes must be the
/// client's preface: after TLS with ALPN `h2`, or cleartext with prior
/// knowledge.
///
/// `limits` applies as it does to HTTP/1: `max_body_bytes` (a larger
/// declared length is answered 413 before the handler runs; a body that
/// crosses it fails the handler's read, and the answer is 413),
/// `max_header_bytes` as SETTINGS_MAX_HEADER_LIST_SIZE (a larger header
/// block resets its stream), `body_timeout_ms` for a request body from its
/// first read to its end and for each write and each read of a streamed
/// response, `handler_timeout_ms` (504), and `header_timeout_ms` for a
/// connection without streams, which then gets GOAWAY. `h2_limits` gives
/// the streams and windows. `coordination` defaults to gaato/mttp's
/// runtime.
///
/// A request carries the `protocol` attribute `h2`, `connection_scheme`
/// from `scheme`, `remote_addr` from `peer`, and `background` when given.
/// Connection-specific response fields (Connection, Keep-Alive,
/// Transfer-Encoding, Upgrade) are left out, a 101 response becomes 500,
/// and `Date` is added unless `auto_date` is false. A response ended
/// before the request body is reset with NO_ERROR (RFC 9113, section 8.1),
/// so the client stops sending it. `activity` hears `true` while the
/// connection has streams and `false` when it has none. `before_close` runs
/// once the last frames are written, before the connection is closed: a
/// TLS connection sends close_notify there (HTTP/2 frames every message, so
/// it may always).
pub async fn serve_h2_conn(
  conn : &@rt.Conn,
  handler : @mttp_core.Handler,
  clock~ : &@rt.Clock,
  timer~ : &@rt.Timer,
  scheme~ : String,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
  h2_limits~ : H2Limits = H2Limits::default(),
  auto_date~ : Bool = true,
  peer? : String,
  on_error~ : (@mttp_core.TransportError) -> Unit = _ => (),
  stopping~ : () -> Bool = () => false,
  activity~ : (Bool) -> Unit = _ => (),
  background? : (async () -> Unit) -> Unit,
  coordination? : &@rt.Coordination,
  before_close? : async () -> Unit noraise,
) -> Unit {
  defer conn.close()
  let session = @h2.H2Session::server(settings={
    ..@h2.H2Settings::server(),
    max_concurrent_streams: h2_limits.max_concurrent_streams,
    stream_window: h2_limits.stream_window,
    connection_window: h2_limits.connection_window,
    max_header_list: limits.max_header_bytes,
  }) catch {
    error => {
      on_error(
        @mttp_core.TransportError(
          kind=Network,
          phase=Unknown,
          detail=error.to_string(),
        ),
      )
      return
    }
  }
  defer session.free()
  let coordination : &@rt.Coordination = match coordination {
    Some(coordination) => coordination
    None => @runtime.RuntimeCoordination::new()
  }
  let served = {
    conn,
    session,
    timer,
    clock,
    limits,
    h2_limits,
    streams: Map([]),
    changes: @mux.Changes::new(coordination, clock, timer),
    handlers: 0,
    dead: false,
  }
  let context : @mux.ServerContext = {
    conn: served,
    changes: served.changes,
    handler,
    limits,
    scheme,
    protocol: "h2",
    auto_date,
    peer,
    clock,
    timer,
    on_error,
    background,
    stopping,
    coordination,
  }
  @async.with_task_group(group => {
    let writer = group.spawn(() => served.write_loop())
    served.read_loop(group, context, stopping, activity)
    // Whatever ended the loop, what the session still has to say (GOAWAY,
    // the last frames of finished streams) goes out before the close, by
    // the writer, which ends once it is said (each write is bounded by
    // `body_timeout_ms`).
    served.dead = true
    for _, entry in served.streams {
      if entry.task is Some(task) {
        task.cancel()
      }
    }
    served.wake()
    writer.wait() catch {
      _ => ()
    }
    // HTTP/2 frames every message, so whatever was cut is seen as cut by
    // its stream, and the close may always be announced (TLS close_notify).
    if before_close is Some(before_close) {
      before_close()
    }
    // What the client sent after the last frame read (a PING after its
    // GOAWAY) is read and dropped for a moment before the close: closing
    // with unread bytes makes the kernel reset the connection, and the
    // client may never see the GOAWAY.
    ignore(
      timer.within(LINGER_MS, () => {
        while (conn.read(max_len=65536) catch { _ => None }) is Some(_) {
          ()
        }
      }),
    )
    group.return_immediately()
  }) catch {
    _ => ()
  }
}

///|
/// Reads frames until the client goes, the connection fails, or a stop or
/// the idle limit has let the last stream finish.
async fn Served::read_loop(
  self : Served,
  group : @async.TaskGroup,
  context : @mux.ServerContext,
  stopping : () -> Bool,
  activity : (Bool) -> Unit,
) -> Unit {
  let mut busy = false
  let mut idle_since = self.clock.now_unix_ms()
  // 0: serving; 1: the notice went; 2: the last GOAWAY went.
  let mut going = 0
  let mut notice_at = 0L
  while !self.dead {
    // nghttp2 reads no more once it sent the GOAWAY of a connection error.
    if !self.session.wants_read() {
      return
    }
    let now = self.clock.now_unix_ms()
    let has_streams = !self.streams.is_empty() || self.handlers > 0
    if has_streams != busy {
      busy = has_streams
      activity(busy)
      if !busy {
        idle_since = now
      }
    }
    if going == 0 &&
      (
        stopping() ||
        (
          !has_streams &&
          now - idle_since >= self.limits.header_timeout_ms.to_int64()
        )
      ) {
      self.session.shutdown_notice() catch {
        _ => ()
      }
      going = 1
      notice_at = now
      self.wake()
    }
    // One round trip after the notice, the real last stream (RFC 9113,
    // section 6.8); a stream opened meanwhile is still served.
    if going == 1 && now - notice_at >= POLL_MS.to_int64() {
      self.session.goaway(NoError) catch {
        _ => ()
      }
      going = 2
      self.wake()
    }
    if going == 2 && !has_streams {
      return
    }
    let chunk : Ref[Bytes?] = Ref(None)
    let failed = Ref(false)
    let read = self.timer.within(POLL_MS, () => {
      chunk.val = self.conn.read(max_len=65536) catch {
        @mttp_core.TransportError(..) => {
          failed.val = true
          None
        }
      }
    })
    if !read {
      // Nothing arrived in time; a cancelled read gives up nothing.
      continue
    }
    guard chunk.val is Some(bytes) else {
      // EOF or a failure: the client is gone.
      if !failed.val {
        self.session.goaway(NoError) catch {
          _ => ()
        }
      }
      return
    }
    let failure = try {
      self.session.recv(bytes)
      None
    } catch {
      @h2.H2Error(..) as error => Some(error)
    }
    self.dispatch(Some((group, context)))
    self.wake()
    // A connection error nghttp2 answered itself (a malformed frame, an
    // invalid PING): it queued GOAWAY and reads no more, so the connection
    // closes once that is written, as RFC 9113, section 5.4.1 asks.
    if failure is None && !self.session.wants_read() {
      return
    }
    if failure is Some(error) {
      (context.on_error)(
        @mttp_core.TransportError(
          kind=Protocol,
          phase=Unknown,
          detail=error.to_string(),
        ),
      )
      return
    }
  }
}

///|
/// Hands the session's events to their streams. With `spawn` (the reader's
/// call), a request starts a task on that group; the writer's call only
/// sees frames sent and streams closed.
fn Served::dispatch(
  self : Served,
  spawn : (@async.TaskGroup, @mux.ServerContext)?,
) -> Unit {
  for event in self.session.events() {
    match event {
      // While the handlers allowed run (cancelled ones still finishing
      // count), a new request is refused rather than started, so a client
      // that opens and resets streams cannot pile up tasks
      // (CVE-2023-44487). The connection is still read: the running
      // handlers need its DATA and WINDOW_UPDATE frames. REFUSED_STREAM
      // tells the client the request was not processed, so it may send it
      // again.
      Headers(stream~, kind=Request, ..) if self.handlers >=
        self.h2_limits.max_concurrent_streams =>
        self.session.reset(stream, RefusedStream) catch {
          _ => ()
        }
      Headers(stream~, kind=Request, fields~, end_stream~) =>
        if spawn is Some((group, context)) {
          let s = @mux.ServerStream::new(stream.to_int64(), ended=end_stream)
          let entry = { stream: s, task: None, }
          self.streams[stream] = entry
          self.handlers += 1
          let task = group.spawn(allow_failure=true, () => {
            defer {
              self.handlers -= 1
              self.streams.remove(stream)
              self.wake()
            }
            context.serve(s, fields)
          })
          entry.task = Some(task)
        }
      Headers(stream~, kind=Trailers, end_stream~, ..) =>
        if end_stream && self.streams.get(stream) is Some(entry) {
          entry.stream.ended = true
        }
      Data(stream~, data) => {
        self.session.consume_connection(data.length())
        match self.streams.get(stream) {
          Some(entry) =>
            if !entry.stream.arrived(data, self.limits.max_body_bytes) {
              self.session.consume_stream(stream, data.length())
            }
          // A stream whose handler finished: its window is given back.
          None => self.session.consume_stream(stream, data.length())
        }
      }
      EndStream(stream~) =>
        if self.streams.get(stream) is Some(entry) {
          entry.stream.ended = true
        }
      Sent(stream~, end_stream~) =>
        if self.streams.get(stream) is Some(entry) {
          entry.stream.sent += 1
          if end_stream {
            entry.stream.sent_end = true
          }
        }
      Closed(stream~, code~) =>
        if self.streams.get(stream) is Some(entry) {
          entry.stream.closed = true
          // Closed before its response was all sent, by any reset, NO_ERROR
          // included: the handler is not waited for. A NO_ERROR reset after
          // the response is the end of a request body nobody reads on, and
          // the task ends by itself (Codex's review of #58: a code of zero
          // was taken for a completed exchange).
          if entry.task is Some(task) &&
            (code != NoError || !entry.stream.sent_end) {
            task.cancel()
          }
        }
      Headers(..) | GoAway(..) | Settings(..) | Drained(..) => ()
      NotSent(..) | TooLarge(..) | PingAck => ()
      @h2.H2Event::.. => ()
    }
  }
}

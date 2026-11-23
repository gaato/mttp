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
/// A response body's queue holds at most this many bytes before its writer
/// waits.
const QUEUE_BYTES : Int32 = 65536

///|
/// Where one request stream stands.
priv struct ServerStream {
  id : Int32
  body : Array[Bytes]
  mut received : Int64
  /// The client ended its half.
  mut ended : Bool
  /// The stream closed, with the code.
  mut closed : @h2.ErrorCode?
  /// The response's last frame went out.
  mut sent_end : Bool
  /// Why the request body cannot be read on (too large, too slow).
  mut failure : @mttp_core.TransportError?
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
  streams : Map[Int32, ServerStream]
  /// Broadcast after every change a waiter may wait for, with `generation`
  /// counting the changes (see `wait`).
  changed : @cond_var.Cond
  mut generation : Int32
  /// Handlers running, cancelled ones still finishing included.
  mut handlers : Int32
  /// The connection can carry nothing more.
  mut dead : Bool
}

///|
fn Served::wake(self : Served) -> Unit {
  self.generation += 1
  self.changed.broadcast()
}

///|
/// Waits for the next change, at most `ms`; false when the time ran out.
/// The change counted is any after the call: `timer.within` suspends before
/// its body waits on the condition, and a broadcast in between would be
/// lost, so the body waits until the generation moves on from the one seen
/// at the call. (A handler started while its request's DATA frames were
/// still being dispatched missed their wake-up and waited out
/// `body_timeout_ms`; h2spec's "Sends multiple DATA frames" found it.)
async fn Served::wait(self : Served, ms : Int32) -> Bool noraise {
  let seen = self.generation
  self.timer.within(ms, () => {
    while self.generation == seen {
      self.changed.wait()
    }
  })
}

///|
/// Writes what the session has to say until the connection ends.
async fn Served::write_loop(
  self : Served,
  group : @async.TaskGroup,
  context : Context,
) -> Unit noraise {
  while !self.dead {
    let output = self.session.output()
    // What serializing it caused: frames sent, streams closed.
    self.dispatch(group, context)
    if output.length() == 0 {
      if !self.session.wants_io() {
        return
      }
      self.changed.wait()
      continue
    }
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
/// block resets its stream), `body_timeout_ms` for each request body read
/// and each write, `handler_timeout_ms` (504), and `header_timeout_ms` for
/// a connection without streams, which then gets GOAWAY. `h2_limits` gives
/// the streams and windows.
///
/// A request carries the `protocol` attribute `h2`, `connection_scheme`
/// from `scheme`, `remote_addr` from `peer`, and `background` when given.
/// Connection-specific response fields (Connection, Keep-Alive,
/// Transfer-Encoding, Upgrade) are left out, a 101 response becomes 500,
/// and `Date` is added unless `auto_date` is false. A response ended
/// before the request body is reset with NO_ERROR (RFC 9113, section 8.1),
/// so the client stops sending it. `activity` hears `true` while the
/// connection has streams and `false` when it has none.
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
  let served = {
    conn,
    session,
    timer,
    clock,
    limits,
    h2_limits,
    streams: Map([]),
    changed: @cond_var.Cond(),
    generation: 0,
    handlers: 0,
    dead: false,
  }
  let context = {
    served,
    handler,
    scheme,
    auto_date,
    peer,
    on_error,
    background,
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => served.write_loop(group, context))
    served.read_loop(group, context, stopping, activity)
    // Whatever ended the loop, what the session still has to say (GOAWAY,
    // the last frames of finished streams) goes out before the close.
    served.dead = true
    for _, stream in served.streams {
      if stream.task is Some(task) {
        task.cancel()
      }
    }
    served.wake()
    let rest = session.output()
    if rest.length() > 0 {
      ignore(
        timer.within(limits.body_timeout_ms, () => {
          conn.write(rest) catch {
            @mttp_core.TransportError(..) => ()
          }
        }),
      )
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
/// What every stream task of a connection needs.
priv struct Context {
  served : Served
  handler : @mttp_core.Handler
  scheme : String
  auto_date : Bool
  peer : String?
  on_error : (@mttp_core.TransportError) -> Unit
  background : ((async () -> Unit) -> Unit)?
}

///|
/// Reads frames until the client goes, the connection fails, or a stop or
/// the idle limit has let the last stream finish.
async fn Served::read_loop(
  self : Served,
  group : @async.TaskGroup,
  context : Context,
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
    self.dispatch(group, context)
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
/// Hands the session's events to their streams, and starts a task for each
/// request.
fn Served::dispatch(
  self : Served,
  group : @async.TaskGroup,
  context : Context,
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
      Headers(stream~, kind=Request, fields~, end_stream~) => {
        let s = {
          id: stream,
          body: [],
          received: 0L,
          ended: end_stream,
          closed: None,
          sent_end: false,
          failure: None,
          task: None,
        }
        self.streams[stream] = s
        self.handlers += 1
        let task = group.spawn(allow_failure=true, () => {
          defer {
            self.handlers -= 1
            self.streams.remove(stream)
            self.wake()
          }
          context.run(s, fields)
        })
        s.task = Some(task)
      }
      Headers(stream~, kind=Trailers, end_stream~, ..) =>
        if end_stream && self.streams.get(stream) is Some(s) {
          s.ended = true
        }
      Data(stream~, data) => {
        self.session.consume_connection(data.length())
        match self.streams.get(stream) {
          Some(s) => {
            s.received += data.length().to_int64()
            if s.received > self.limits.max_body_bytes.to_int64() {
              let limit = self.limits.max_body_bytes
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
          None => ()
        }
      }
      EndStream(stream~) =>
        if self.streams.get(stream) is Some(s) {
          s.ended = true
        }
      Sent(stream~, end_stream=true) =>
        if self.streams.get(stream) is Some(s) {
          s.sent_end = true
        }
      Closed(stream~, code~) =>
        if self.streams.get(stream) is Some(s) {
          s.closed = Some(code)
          // A reset before the response ended: its handler is not waited for.
          if code != NoError && s.task is Some(task) {
            task.cancel()
          }
        }
      Headers(..) | Sent(..) | GoAway(..) | Settings(..) | Drained(..) => ()
      NotSent(..) | TooLarge(..) | PingAck => ()
      @h2.H2Event::.. => ()
    }
  }
}

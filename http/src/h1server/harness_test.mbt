// The test harness: the engine serves the server end of an in-memory pair on
// one Driver, and a minimal HTTP/1.1 client reads what it answers on the
// other end. `Harness::run` checks that no task outlives the test body and
// that every connection the engine served was closed exactly once.

///|
priv struct Harness {
  driver : @driver.Driver
  coordination : &@rt.Coordination
  clock : &@rt.Clock
  timer : &@rt.Timer
  /// What the engine reported, in order.
  errors : Array[@http.TransportError]
  /// How often each served connection was closed, in serving order.
  closes : Array[() -> Int32]
}

///|
fn Harness::new() -> Harness {
  let driver = @driver.Driver::new()
  {
    driver,
    coordination: @sim.SimCoordination::new(driver),
    clock: @sim.SimClock::new(driver),
    timer: @sim.SimTimer::new(driver),
    errors: [],
    closes: [],
  }
}

///|
/// Runs `f` on the driver and requires that it leaves no task behind and
/// that every served connection was closed once.
fn Harness::run(self : Harness, f : async () -> Unit) -> Unit raise {
  self.driver.run(() => {
    f()
    // Let finished children unwind before counting.
    self.driver.pause()
    assert_eq(self.driver.live_tasks(), 1, msg="a task outlived the test")
    assert_eq(
      self.driver.pending_timers(),
      0,
      msg="a deadline outlived the test",
    )
  })
  for i, closes in self.closes {
    assert_eq(closes(), 1, msg="connection \{i} was not closed once")
  }
}

///|
/// Serves `conn` in a new task, recording reports in `errors`.
fn Harness::serve_on(
  self : Harness,
  conn : &@rt.Conn,
  handler : @http.Handler,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
  scheme~ : String = "http",
  peer? : String,
  background? : (async () -> Unit) -> Unit,
  stopping~ : () -> Bool = () => false,
) -> @driver.Task {
  self.driver.spawn(() => {
    @h1server.serve_conn(
      conn,
      handler,
      clock=self.clock,
      timer=self.timer,
      coordination=self.coordination,
      scheme~,
      limits~,
      peer?,
      background?,
      stopping~,
      on_error=error => self.errors.push(error),
    )
  })
}

///|
/// Serves the server end of a new pair in a task and returns a client on
/// the other end.
fn Harness::serve(
  self : Harness,
  handler : @http.Handler,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
  chunk_bytes~ : Int32 = 65536,
  scheme~ : String = "http",
  peer? : String,
  background? : (async () -> Unit) -> Unit,
) -> (Client, @driver.Task) {
  let (client, server) = @sim.pair(self.coordination, chunk_bytes~)
  self.closes.push(() => server.closes())
  let task = self.serve_on(
    server,
    handler,
    limits~,
    scheme~,
    peer?,
    background?,
  )
  ({ conn: client, pending: b"", }, task)
}

///|
/// Sends `bytes`, ends the client's sending half and returns everything the
/// engine wrote until it closed the connection.
fn Harness::exchange(
  self : Harness,
  bytes : Bytes,
  handler : @http.Handler,
  limits~ : @h1server.ServerLimits = @h1server.ServerLimits::default(),
  chunk_bytes~ : Int32 = 65536,
) -> String raise {
  let mut out = ""
  self.run(() => {
    let (client, task) = self.serve(handler, limits~, chunk_bytes~)
    client.conn.write(bytes)
    client.conn.shutdown_write()
    out = client.rest()
    ignore(task.wait())
    client.conn.close()
  })
  out
}

///|
/// A minimal HTTP/1.1 client on the other end of a pair.
priv struct Client {
  conn : @sim.SimConn
  mut pending : Bytes
}

///|
/// One response as the client read it.
priv struct Reply {
  status : Int32
  headers : @http.Headers
  body : Bytes
}

///|
async fn Client::fill(self : Client) -> Bool {
  guard self.conn.read(max_len=65536) is Some(bytes) else { return false }
  self.pending = self.pending + bytes
  true
}

///|
async fn Client::send(self : Client, text : String) -> Unit {
  self.conn.write(@http.encode_utf8(text))
}

///|
/// Reads the next response to a request of `meth`, or `None` at EOF before
/// one. An informational response is returned on its own.
async fn Client::response(self : Client, meth~ : @http.Method = Get) -> Reply? {
  let decoder = @h1.HeadDecoder::new()
  let mut raw = b""
  for ;; {
    if self.pending.is_empty() && !self.fill() {
      return None
    }
    let result = decoder.feed(self.pending)
    self.pending = self.pending[result.consumed:].to_owned()
    if result.head is Some(head) {
      raw = head
      break
    }
  }
  let head = @h1.parse_response_head(raw)
  let body = Buffer()
  match @h1.response_framing(head.headers, status=head.status, meth~) {
    Length(n) =>
      while body.length().to_int64() < n {
        if self.pending.is_empty() && !self.fill() {
          fail("EOF in the response body")
        }
        let take = (n - body.length().to_int64())
          .min(self.pending.length().to_int64())
          .to_int()
        body.write_bytes(self.pending[:take])
        self.pending = self.pending[take:].to_owned()
      }
    Chunked => {
      let decoder = @h1.ChunkedDecoder::new(@h1.Limits::default())
      for ;; {
        if self.pending.is_empty() && !self.fill() {
          fail("EOF in a chunked response body")
        }
        let decoded = decoder.feed(self.pending)
        for chunk in decoded.chunks {
          body.write_bytes(chunk)
        }
        self.pending = self.pending[decoded.consumed:].to_owned()
        if decoded.done {
          break
        }
      }
    }
    UntilClose => {
      body.write_bytes(self.pending)
      self.pending = b""
      while self.fill() {
        body.write_bytes(self.pending)
        self.pending = b""
      }
    }
    _ => ()
  }
  Some({ status: head.status, headers: head.headers, body: body.to_bytes(), })
}

///|
/// Reads the next response, which must be there.
async fn Client::expect(self : Client, meth~ : @http.Method = Get) -> Reply {
  guard self.response(meth~) is Some(reply) else { fail("expected a response") }
  reply
}

///|
/// Everything left until EOF, as text.
async fn Client::rest(self : Client) -> String {
  let out = Buffer()
  out.write_bytes(self.pending)
  self.pending = b""
  while self.conn.read(max_len=65536) is Some(bytes) {
    out.write_bytes(bytes)
  }
  @utf8.decode(out.to_bytes())
}

///|
fn Reply::text(self : Reply) -> String raise {
  @utf8.decode(self.body)
}

///|
/// A request head with `fields` (each ending in CRLF) and no body.
fn get(path : String, fields~ : String = "") -> String {
  "GET \{path} HTTP/1.1\r\nHost: example.test\r\n\{fields}\r\n"
}

///|
/// A POST with a Content-Length body.
fn post(path : String, body : String, fields~ : String = "") -> String {
  "POST \{path} HTTP/1.1\r\nHost: example.test\r\n\{fields}Content-Length: \{@http.encode_utf8(body).length()}\r\n\r\n\{body}"
}

///|
/// Reads the whole request body, at most `limit` bytes.
async fn body_of(
  request : @http.Request,
  limit~ : Int32 = 1 << 20,
) -> Bytes raise @http.TransportError {
  match request.body {
    Stream(stream) => @http.read_bounded(stream.take(), limit)
    Bytes(bytes) => bytes
    _ => b""
  }
}

///|
/// A handler answering `status` with `text`.
fn reply(text : String, status~ : Int32 = 200) -> @http.Handler {
  _ => @http.Response::new(status, body=Bytes(@http.encode_utf8(text)))
}

///|
/// A handler echoing the request body it read, or `caught` when reading
/// failed.
fn echo() -> @http.Handler {
  request => {
    let body = body_of(request) catch { _ => b"caught" }
    @http.Response::new(200, body=Bytes(body))
  }
}

///|
/// A failure's kind and phase, for matching in expectations.
fn kind_phase(error : @http.TransportError) -> (@http.Kind, @http.Phase) {
  let @http.TransportError(kind~, phase~, ..) = error
  (kind, phase)
}

///|
/// A response stream played from `pieces`, failing with `failure` once they
/// ran out when set; counts its closes.
priv struct Pieces {
  pieces : Array[Bytes]
  failure : @http.TransportError?
  mut closes : Int32
  mut closed : Bool
}

///|
fn Pieces::new(
  pieces : Array[Bytes],
  failure? : @http.TransportError,
) -> Pieces {
  { pieces: pieces.copy(), failure, closes: 0, closed: false, }
}

///|
impl @http.BodyStream for Pieces with fn read_some(self) {
  if self.closed {
    return None
  }
  if !self.pieces.is_empty() {
    return Some(self.pieces.remove(0))
  }
  if self.failure is Some(error) {
    raise error
  }
  None
}

///|
impl @http.BodyStream for Pieces with fn close(self) {
  if !self.closed {
    self.closed = true
    self.closes += 1
  }
}

///|
/// A connection that records the size of each read it was asked for and
/// each write, over another connection.
priv struct Recording {
  inner : &@rt.Conn
  read_sizes : Array[Int32]
  write_sizes : Array[Int32]
  mut bytes_read : Int32
  mut active_reads : Int32
  mut max_readers : Int32
}

///|
fn Recording::new(inner : &@rt.Conn) -> Recording {
  {
    inner,
    read_sizes: [],
    write_sizes: [],
    bytes_read: 0,
    active_reads: 0,
    max_readers: 0,
  }
}

///|
impl @rt.Conn for Recording with fn read(self, max_len~) {
  self.active_reads += 1
  self.max_readers = self.max_readers.max(self.active_reads)
  defer {
    self.active_reads -= 1
  }
  self.read_sizes.push(max_len)
  let bytes = self.inner.read(max_len~)
  if bytes is Some(bytes) {
    self.bytes_read += bytes.length()
  }
  bytes
}

///|
impl @rt.Conn for Recording with fn write(self, bytes) {
  self.write_sizes.push(bytes.length())
  self.inner.write(bytes)
}

///|
impl @rt.Conn for Recording with fn close(self) {
  self.inner.close()
}

///|
/// A connection that plays `steps` for reads and whose writes never
/// complete, like a peer that stopped reading.
priv struct Stalled {
  reads : @sim.ScriptedConn
  stuck : &@rt.Signal
  mut writes : Int32
  mut closed : Bool
}

///|
impl @rt.Conn for Stalled with fn read(self, max_len~) {
  self.reads.read(max_len~)
}

///|
impl @rt.Conn for Stalled with fn write(self, _) {
  self.writes += 1
  self.stuck.wait()
  if self.closed {
    raise @http.TransportError(
      kind=Network,
      phase=Write,
      detail="closed while writing",
    )
  }
}

///|
impl @rt.Conn for Stalled with fn close(self) {
  self.closed = true
  self.reads.close()
  self.stuck.notify()
}

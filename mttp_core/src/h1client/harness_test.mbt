// The test harness: a client over sim ports on one Driver, a dialer that
// hands out prepared connections and records every dial, and a minimal
// HTTP/1.1 peer for the connections that need one. `Harness::run` checks
// that no task outlives the test body; `Harness::finish` closes the client
// and checks that every dialled connection is closed.

///|
/// What the test dialer does on the next connect.
priv enum Dial {
  Hand(&@rt.Conn)
  /// Never connects: waits until cancelled.
  Hang
}

///|
priv struct TestDialer {
  coordination : &@rt.Coordination
  queue : Array[Dial]
  dialed : Array[(String, Int32)]
  tls_hosts : Array[String]
  /// Raised by every TLS upgrade when set.
  mut tls_failure : @mttp_core.TransportError?
}

///|
impl @rt.Dialer for TestDialer with fn connect(self, host~, port~) {
  self.dialed.push((host, port))
  guard !self.queue.is_empty() else {
    raise @mttp_core.TransportError(
      kind=Connect,
      phase=Dial,
      detail="no prepared connection",
    )
  }
  match self.queue.remove(0) {
    Hand(conn) => conn
    Hang => {
      self.coordination.signal().wait()
      raise @mttp_core.TransportError(kind=Connect, phase=Dial, detail="hung")
    }
  }
}

///|
impl @rt.Dialer for TestDialer with fn start_tls(self, conn, host~) {
  self.tls_hosts.push(host)
  if self.tls_failure is Some(error) {
    raise error
  }
  conn
}

///|
priv struct Harness {
  driver : @driver.Driver
  coordination : &@rt.Coordination
  dialer : TestDialer
  client : @h1client.Client
  /// How often each prepared connection was closed, in preparation order.
  closes : Array[() -> Int32]
}

///|
fn Harness::new(
  config~ : @h1client.ClientConfig = @h1client.ClientConfig::default(),
) -> Harness {
  let driver = @driver.Driver::new()
  let coordination : &@rt.Coordination = @sim.SimCoordination::new(driver)
  let clock : &@rt.Clock = @sim.SimClock::new(driver)
  let timer : &@rt.Timer = @sim.SimTimer::new(driver)
  let dialer = TestDialer::{
    coordination,
    queue: [],
    dialed: [],
    tls_hosts: [],
    tls_failure: None,
  }
  let client = @h1client.Client::new(
    dialer~,
    clock~,
    timer~,
    coordination~,
    config~,
  )
  { driver, coordination, dialer, client, closes: [], }
}

///|
/// Prepares a scripted connection for the next dial.
fn Harness::scripted(
  self : Harness,
  steps : Array[@sim.ReadStep],
  write_error? : @mttp_core.TransportError,
) -> @sim.ScriptedConn {
  let conn = @sim.ScriptedConn::new(steps, write_error?)
  self.dialer.queue.push(Hand(conn))
  self.closes.push(() => conn.closes())
  conn
}

///|
/// Prepares the client end of an in-memory pair for the next dial and
/// returns a peer on the other end.
fn Harness::peer(self : Harness, chunk_bytes? : Int32) -> Peer {
  let (client_end, server_end) = @sim.pair(self.coordination, chunk_bytes?)
  self.dialer.queue.push(Hand(client_end))
  self.closes.push(() => client_end.closes())
  { conn: server_end, pending: b"", }
}

///|
/// Makes the next dial hang until cancelled.
fn Harness::hang(self : Harness) -> Unit {
  self.dialer.queue.push(Hang)
}

///|
/// Runs `f` on the driver and requires that it leaves no task behind.
fn Harness::run(self : Harness, f : async () -> Unit) -> Unit raise {
  self.driver.run(() => {
    f()
    // Let finished children unwind before counting.
    self.driver.pause()
    assert_eq(self.driver.live_tasks(), 1, msg="a task outlived the test")
  })
}

///|
/// Closes the client and requires every prepared connection that was
/// dialled to be closed, and nothing to stay parked.
fn Harness::finish(self : Harness) -> Unit raise {
  self.client.close()
  assert_eq(self.client.idle_connections(), 0)
  let dialled = self.dialer.dialed.length().min(self.closes.length())
  for i in 0..<dialled {
    assert_eq(self.closes[i](), 1, msg="connection \{i} was not closed")
  }
}

///|
/// The options of a buffered exchange admitting at most `max_bytes`.
fn exchange(
  max_bytes~ : Int32 = 1 << 20,
  timeout_ms? : Int32,
) -> @mttp_core.SendOptions {
  { timeout_ms, body: Exchange(max_bytes~), }
}

///|
/// The options of a streamed exchange.
fn streaming(idle_ms? : Int32, timeout_ms? : Int32) -> @mttp_core.SendOptions {
  { timeout_ms, body: Stream(idle_ms~), }
}

///|
/// Reads a whole response body and closes the response.
async fn body_of(response : @mttp_core.Response) -> Bytes {
  defer response.close()
  match response.body {
    Empty => b""
    Bytes(bytes) => bytes
    Stream(stream) => @mttp_core.read_bounded(stream.take(), 64 << 20)
    @mttp_core.Body::.. => fail("unexpected body kind")
  }
}

///|
/// Sends `request` and returns the whole body as text.
async fn fetch(
  client : @h1client.Client,
  request : @mttp_core.Request,
  options~ : @mttp_core.SendOptions = exchange(),
) -> String {
  @utf8.decode(body_of(client.send(request, options)))
}

///|
/// A failure's kind and phase, for matching in expectations.
fn kind_phase(error : Error) -> (@mttp_core.Kind, @mttp_core.Phase) raise {
  guard error is @mttp_core.TransportError(kind~, phase~, ..) else {
    fail("not a TransportError: \{error}")
  }
  (kind, phase)
}

///|
/// Runs `f`, which must raise a TransportError, and returns its kind and
/// phase.
async fn failing(f : async () -> Unit) -> (@mttp_core.Kind, @mttp_core.Phase) {
  try f() catch {
    error => kind_phase(error)
  } noraise {
    _ => fail("expected a TransportError")
  }
}

///|
/// One request as the peer read it.
priv struct Received {
  head : @h1.ParsedRequest
  /// The head bytes as they arrived.
  raw : Bytes
  body : Bytes
}

///|
/// A minimal HTTP/1.1 peer on the server end of a pair.
priv struct Peer {
  conn : @sim.SimConn
  mut pending : Bytes
}

///|
async fn Peer::fill(self : Peer) -> Bool raise @mttp_core.TransportError {
  guard self.conn.read(max_len=65536) is Some(bytes) else { return false }
  self.pending = self.pending + bytes
  true
}

///|
/// Reads the next request, its body framed as the head says, or `None` at
/// EOF before a request.
async fn Peer::request(self : Peer) -> Received? {
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
  let head = @h1.parse_request_head(raw)
  let body = Buffer()
  match @h1.request_framing(head.headers) {
    Length(n) =>
      while body.length().to_int64() < n {
        if self.pending.is_empty() && !self.fill() {
          fail("EOF in the request body")
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
          fail("EOF in a chunked request body")
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
    _ => ()
  }
  Some({ head, raw, body: body.to_bytes(), })
}

///|
async fn Peer::respond(self : Peer, bytes : Bytes) -> Unit {
  self.conn.write(bytes)
}

///|
/// Answers every request on the connection with `response` until EOF, and
/// returns the requests.
async fn Peer::serve(self : Peer, response : Bytes) -> Array[Received] {
  let seen = []
  while self.request() is Some(request) {
    seen.push(request)
    self.respond(response)
  }
  seen
}

///|
/// The head of a response with `body`, framed by Content-Length.
fn ok(body : String, status~ : Int32 = 200, fields~ : String = "") -> Bytes {
  let payload = @mttp_core.encode_utf8(body)
  @mttp_core.encode_utf8(
    "HTTP/1.1 \{status} \{@mttp_core.reason_phrase(status)}\r\n\{fields}content-length: \{payload.length()}\r\n\r\n",
  ) +
  payload
}

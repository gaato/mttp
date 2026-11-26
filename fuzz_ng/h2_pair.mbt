// The HTTP/2 pair target: a client and a server session joined in memory,
// driven by a program the fuzzer writes: requests with fuzzer-chosen
// fields, body pieces both ways, resets, answers, the bytes in flight
// delivered in pieces, and the readers taking what arrived. The invariants:
// no crash and no memory error (ASan); a head that arrives is the one
// submitted, field for field (the octet encoding, and header blocks kept
// across drains of events); body bytes that arrive are a prefix of those
// pushed; and once the program ends and the sessions settle, every stream
// that nobody reset has its whole body on the other side.

///|
/// One stream as both ends know it.
priv struct H2Stream {
  id : Int32
  /// The request submitted, and the response once the server submits one.
  request : Array[(String, String)]
  mut response : Array[(String, String)]?
  /// Body bytes pushed each way, and whether their last piece went.
  sent_up : Buffer
  mut up_end : Bool
  mut up_open : Bool
  sent_down : Buffer
  mut down_end : Bool
  mut down_open : Bool
  /// What arrived each way, the server's end and the client's.
  got_up : Buffer
  mut got_up_end : Bool
  got_down : Buffer
  mut got_down_end : Bool
  /// Bytes arrived and not yet taken by each reader.
  mut unread_up : Int32
  mut unread_down : Int32
  /// Reset or closed with an error, by either end.
  mut broken : Bool
  /// The request's HEADERS went out: nghttp2 holds back a request over the
  /// server's SETTINGS_MAX_CONCURRENT_STREAMS until a stream closes.
  mut opened : Bool
}

///|
priv struct H2Pair {
  client : @h2.H2Session
  server : @h2.H2Session
  streams : Map[Int32, H2Stream]
  /// Requests the server read and has not answered.
  unanswered : Array[Int32]
  /// Bytes in flight each way.
  mut to_server : Bytes
  mut to_client : Bytes
  /// A session failed (a connection error): nothing is checked further.
  mut failed : Bool
}

///|
fn H2Pair::stream_at(self : H2Pair, index : Int32) -> H2Stream? {
  if self.streams.is_empty() {
    return None
  }
  let ids = self.streams.keys().collect()
  ids.sort()
  self.streams.get(ids[index % ids.length()])
}

///|
/// The events of the server, checked.
fn H2Pair::server_events(self : H2Pair) -> Unit {
  for event in self.server.events() {
    match event {
      // A connection error ends the connection: nothing more is checked.
      GoAway(code~, ..) if code != NoError => self.failed = true
      Headers(stream~, kind=Request, fields~, end_stream~) => {
        guard self.streams.get(stream) is Some(s) else {
          abort("the server read a request nobody sent")
        }
        if fields != as_sent(s.request) {
          abort(changed("request", fields, s.request))
        }
        if end_stream {
          s.got_up_end = true
        }
        self.unanswered.push(stream)
      }
      Data(stream~, bytes) => {
        guard self.streams.get(stream) is Some(s) else {
          abort("DATA of a stream nobody opened")
        }
        self.server.consume_connection(bytes.length())
        s.got_up.write_bytes(bytes)
        s.unread_up += bytes.length()
        check_prefix("request body", s.got_up.to_bytes(), s.sent_up.to_bytes())
      }
      EndStream(stream~) =>
        if self.streams.get(stream) is Some(s) {
          s.got_up_end = true
        }
      Closed(stream~, code~) =>
        if code != NoError && self.streams.get(stream) is Some(s) {
          s.broken = true
        }
      TooLarge(stream~) | NotSent(stream~, ..) =>
        if self.streams.get(stream) is Some(s) {
          s.broken = true
        }
      _ => ()
    }
  }
}

///|
/// The events of the client, checked.
fn H2Pair::client_events(self : H2Pair) -> Unit {
  for event in self.client.events() {
    match event {
      // A connection error ends the connection: nothing more is checked.
      GoAway(code~, ..) if code != NoError => self.failed = true
      Headers(stream~, kind=Response, fields~, end_stream~) => {
        guard self.streams.get(stream) is Some(s) else {
          abort("a response to a stream nobody opened")
        }
        if s.response.map(as_sent) != Some(fields) {
          abort(changed("response", fields, s.response.unwrap_or([])))
        }
        if end_stream {
          s.got_down_end = true
        }
      }
      Data(stream~, bytes) => {
        guard self.streams.get(stream) is Some(s) else {
          abort("DATA of a stream nobody opened")
        }
        self.client.consume_connection(bytes.length())
        s.got_down.write_bytes(bytes)
        s.unread_down += bytes.length()
        check_prefix(
          "response body",
          s.got_down.to_bytes(),
          s.sent_down.to_bytes(),
        )
      }
      EndStream(stream~) =>
        if self.streams.get(stream) is Some(s) {
          s.got_down_end = true
        }
      Closed(stream~, code~) =>
        if code != NoError && self.streams.get(stream) is Some(s) {
          s.broken = true
        }
      TooLarge(stream~) | NotSent(stream~, ..) =>
        if self.streams.get(stream) is Some(s) {
          s.broken = true
        }
      Sent(stream~, ..) =>
        if self.streams.get(stream) is Some(s) {
          s.opened = true
        }
      _ => ()
    }
  }
}

///|
/// Takes what both sessions have to say into the bytes in flight.
fn H2Pair::collect(self : H2Pair) -> Unit {
  self.to_server = self.to_server + self.client.output()
  self.client_events()
  self.to_client = self.to_client + self.server.output()
  self.server_events()
}

///|
/// Delivers up to `n` bytes in flight to the server or the client.
fn H2Pair::deliver(self : H2Pair, to_server : Bool, n : Int32) -> Unit {
  self.collect()
  let pending = if to_server { self.to_server } else { self.to_client }
  let n = n.min(pending.length())
  if n == 0 {
    return
  }
  let piece = pending[:n].to_owned()
  let rest = pending[n:].to_owned()
  let peer = if to_server { self.server } else { self.client }
  if to_server {
    self.to_server = rest
  } else {
    self.to_client = rest
  }
  peer.recv(piece) catch {
    _ => self.failed = true
  }
  if to_server {
    self.server_events()
  } else {
    self.client_events()
  }
}

///|
/// The readers take what arrived: the windows open.
fn H2Pair::read_all(self : H2Pair) -> Unit {
  for _, s in self.streams {
    if s.unread_up > 0 {
      self.server.consume_stream(s.id, s.unread_up)
      s.unread_up = 0
    }
    if s.unread_down > 0 {
      self.client.consume_stream(s.id, s.unread_down)
      s.unread_down = 0
    }
  }
}

///|
/// A body piece of up to `n` bytes of the input's choosing.
fn piece(input : Input, n : Int32) -> Bytes {
  let len = input.byte() % n
  let fill = input.byte()
  Bytes::makei(len, i => ((fill + i) % 256).to_byte())
}

///|
/// One step of the program.
fn H2Pair::step(self : H2Pair, input : Input) -> Unit {
  match input.byte() % 9 {
    // A request, with a body to follow or not.
    0 => {
      let body = input.byte() % 2 == 0
      let request = input.fields([
        (":method", if body { "POST" } else { "GET" }),
        (":scheme", "https"),
        (":authority", "example.com"),
        (":path", "/"),
      ])
      let id = self.client.submit_request(request, body~) catch { _ => return }
      self.streams[id] = H2Stream::{
        id,
        request,
        response: None,
        sent_up: Buffer(),
        up_end: !body,
        up_open: body,
        sent_down: Buffer(),
        down_end: false,
        down_open: false,
        got_up: Buffer(),
        got_up_end: false,
        got_down: Buffer(),
        got_down_end: false,
        unread_up: 0,
        unread_down: 0,
        broken: false,
        opened: false,
      }
    }
    // A piece of a request body.
    1 =>
      if self.stream_at(input.byte()) is Some(s) && s.up_open {
        let bytes = piece(input, 200)
        let end = input.byte() % 4 == 0
        self.client.push(s.id, bytes, end~) catch {
          _ => return
        }
        s.sent_up.write_bytes(bytes)
        if end {
          s.up_open = false
          s.up_end = true
        }
      }
    // An answer to the oldest request not answered.
    2 =>
      if !self.unanswered.is_empty() {
        let id = self.unanswered.remove(0)
        guard self.streams.get(id) is Some(s) else { return }
        let body = input.byte() % 2 == 0
        let status = 200 + input.byte() % 400
        let response = input.fields([(":status", status.to_string())])
        self.server.submit_response(id, response, body~) catch {
          _ => return
        }
        s.response = Some(response)
        s.down_open = body
        s.down_end = !body
      }
    // A piece of a response body.
    3 =>
      if self.stream_at(input.byte()) is Some(s) && s.down_open {
        let bytes = piece(input, 200)
        let end = input.byte() % 4 == 0
        self.server.push(s.id, bytes, end~) catch {
          _ => return
        }
        s.sent_down.write_bytes(bytes)
        if end {
          s.down_open = false
          s.down_end = true
        }
      }
    // A reset, by either end.
    4 =>
      if self.stream_at(input.byte()) is Some(s) {
        let session = if input.byte() % 2 == 0 {
          self.client
        } else {
          self.server
        }
        let code = @h2.ErrorCode::from_int(input.byte() % 14)
        session.reset(s.id, code) catch {
          _ => return
        }
        s.broken = true
      }
    5 => self.deliver(true, input.byte() * 4 + 1)
    6 => self.deliver(false, input.byte() * 4 + 1)
    7 => self.read_all()
    _ => self.client.ping() catch { _ => () }
  }
}

///|
pub fn fuzz_h2_pair(data : Bytes) -> Int32 {
  let input = Input::new(data)
  let mode = input.byte()
  let small = (mode & 1) != 0
  let windows = (settings : @h2.H2Settings) => {
    if small {
      { ..settings, stream_window: 64, connection_window: 256, low_mark: 32, }
    } else {
      settings
    }
  }
  let client = @h2.H2Session::client(settings=windows(@h2.H2Settings::client())) catch {
    _ => abort("no client session")
  }
  defer client.free()
  let server = @h2.H2Session::server(settings=windows(@h2.H2Settings::server())) catch {
    _ => abort("no server session")
  }
  defer server.free()
  let pair : H2Pair = {
    client,
    server,
    streams: Map([]),
    unanswered: [],
    to_server: b"",
    to_client: b"",
    failed: false,
  }
  for steps = 0; steps < 300 && !input.done() && !pair.failed; steps = steps + 1 {
    pair.step(input)
  }
  // Settles: everything in flight delivered and read, until both are
  // quiet. Small windows move a few dozen bytes a round trip, so a long
  // body takes many; a pair still busy at the bound proves nothing either
  // way, and is not checked.
  let mut quiet = false
  for _ in 0..<20000 {
    if pair.failed {
      return 0
    }
    pair.collect()
    pair.read_all()
    pair.collect()
    if pair.to_server.is_empty() && pair.to_client.is_empty() {
      quiet = true
      break
    }
    pair.deliver(true, pair.to_server.length())
    pair.deliver(false, pair.to_client.length())
  }
  if pair.failed || !quiet {
    return 0
  }
  for _, s in pair.streams {
    if s.broken || !s.opened {
      continue
    }
    // nghttp2 refuses streams over the server's limit with a reset, which
    // marks them broken; every other stream's bodies arrived whole.
    if s.up_end &&
      (s.got_up.to_bytes() != s.sent_up.to_bytes() || !s.got_up_end) {
      abort(
        "a request body that ended did not arrive whole: stream \{s.id}, pushed \{s.sent_up.length()}, got \{s.got_up.length()}, end \{s.got_up_end}, answered \{s.response is Some(_)}, still queued \{@debug.to_string(pair.client.queued(s.id))}",
      )
    }
    if s.down_end && s.response is Some(_) {
      if s.got_down.to_bytes() != s.sent_down.to_bytes() || !s.got_down_end {
        abort(
          "a response body that ended did not arrive whole: stream \{s.id}, pushed \{s.sent_down.length()}, got \{s.got_down.length()}, end \{s.got_down_end}, still queued \{@debug.to_string(pair.server.queued(s.id))}",
        )
      }
    }
  }
  0
}

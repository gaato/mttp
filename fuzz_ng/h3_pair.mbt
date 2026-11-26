// The HTTP/3 pair target: a QUIC client and server joined in memory, past
// their handshake, driven by a program as the HTTP/2 pair is, and also fed
// datagrams the fuzzer writes. The invariants: no crash and no memory error
// (ASan) in ngtcp2, nghttp3 or h3_stub.c; a head that arrives is the one
// submitted (the octet encoding, per-stream header bounds, header blocks
// across drains); and body bytes that arrive are a prefix of those pushed.
// QUIC paces what it sends on the clock, which a fuzz run does not move, so
// whether everything arrives in the end is not checked here; the tests are
// where it is.

///|
/// The TLS contexts, made once: their certificates do not change.
let contexts : Ref[(@h3.ClientQuic, @h3.ServerQuic)?] = Ref(None)

///|
fn contexts_once() -> (@h3.ClientQuic, @h3.ServerQuic) {
  match contexts.val {
    Some(both) => both
    None => {
      let client = @h3.ClientQuic::new(trust=Insecure) catch {
        _ => abort("no client context")
      }
      let server = @h3.ServerQuic::from_pem(chain=server_chain, key=server_key) catch {
        _ => abort("no server context")
      }
      contexts.val = Some((client, server))
      (client, server)
    }
  }
}

///|
/// Whether a field name has only the characters RFC 9114 allows in one
/// (section 4.2, the tokens of RFC 9110 in lower case).
fn valid_name(name : String) -> Bool {
  !name.is_empty() &&
  name
  .iter()
  .all(c => c is ('a'..<='z' | '0'..<='9') || "!#$%&'*+-.^_`|~".contains_char(c))
}

///|
/// Whether a field value is one nghttp3 lets through: RFC 9110's field
/// value characters (HTAB, SP, VCHAR, obs-text; section 5.5), stricter than
/// RFC 9114's NUL, CR and LF, and no white space first or last.
fn valid_value(value : String) -> Bool {
  value.iter().all(c => c is ('\t' | ' '..<='~' | '\u{80}'..<='\u{ff}')) &&
  !value.has_prefix(" ") &&
  !value.has_prefix("\t") &&
  !value.has_suffix(" ") &&
  !value.has_suffix("\t")
}

///|
/// Whether `got` is `sent` less invalid fields, in order. nghttp3 drops a
/// field whose name or value has a character RFC 9114 forbids there
/// (NGHTTP3_ERR_REMOVE_HTTP_HEADER, with no setting to make it a malformed
/// message instead), so those may be missing; no other field may be.
fn arrived_intact(
  got : Array[(String, String)],
  sent : Array[(String, String)],
) -> Bool {
  let mut i = 0
  for field in sent {
    if i < got.length() && got[i] == field {
      i += 1
    } else if field.0.has_prefix(":") ||
      (valid_name(field.0) && valid_value(field.1)) {
      return false
    }
  }
  i == got.length()
}

///|
priv struct H3Stream {
  id : Int64
  request : Array[(String, String)]
  mut response : Array[(String, String)]?
  sent_up : Buffer
  mut up_open : Bool
  sent_down : Buffer
  mut down_open : Bool
  got_up : Buffer
  got_down : Buffer
  mut unread_up : Int32
  mut unread_down : Int32
}

///|
priv struct H3Pair {
  client : @h3.QuicConn
  server : @h3.QuicConn
  streams : Map[Int64, H3Stream]
  unanswered : Array[Int64]
  to_server : Array[Bytes]
  to_client : Array[Bytes]
  mut failed : Bool
}

///|
fn H3Pair::stream_at(self : H3Pair, index : Int32) -> H3Stream? {
  if self.streams.is_empty() {
    return None
  }
  let ids = self.streams.keys().collect()
  ids.sort()
  self.streams.get(ids[index % ids.length()])
}

///|
fn H3Pair::server_events(self : H3Pair) -> Unit {
  for event in self.server.events() {
    match event {
      Headers(stream~, fields~, ..) =>
        match self.streams.get(stream) {
          Some(s) if s.response is None && !self.unanswered.contains(stream) => {
            if !arrived_intact(fields, as_sent(s.request)) {
              abort(changed("request", fields, s.request))
            }
            self.unanswered.push(stream)
          }
          // Trailers are not passed on.
          Some(_) => ()
          None => abort("the server read a request nobody sent")
        }
      Data(stream~, bytes) => {
        guard self.streams.get(stream) is Some(s) else {
          abort("DATA of a stream nobody opened")
        }
        s.got_up.write_bytes(bytes)
        s.unread_up += bytes.length()
        check_prefix("request body", s.got_up.to_bytes(), s.sent_up.to_bytes())
      }
      ConnectionClosed(..) => self.failed = true
      _ => ()
    }
  }
}

///|
fn H3Pair::client_events(self : H3Pair) -> Unit {
  for event in self.client.events() {
    match event {
      Headers(stream~, fields~, ..) => {
        guard self.streams.get(stream) is Some(s) else {
          abort("a response to a stream nobody opened")
        }
        guard s.response is Some(response) &&
          arrived_intact(fields, as_sent(response)) else {
          abort(changed("response", fields, s.response.unwrap_or([])))
        }
      }
      Data(stream~, bytes) => {
        guard self.streams.get(stream) is Some(s) else {
          abort("DATA of a stream nobody opened")
        }
        s.got_down.write_bytes(bytes)
        s.unread_down += bytes.length()
        check_prefix(
          "response body",
          s.got_down.to_bytes(),
          s.sent_down.to_bytes(),
        )
      }
      ConnectionClosed(..) => self.failed = true
      _ => ()
    }
  }
}

///|
/// Takes the datagrams both ends have to send.
fn H3Pair::collect(self : H3Pair) -> Unit {
  let up = self.client.datagrams() catch {
    _ => {
      self.failed = true
      []
    }
  }
  self.to_server.append(up)
  self.client_events()
  let down = self.server.datagrams() catch {
    _ => {
      self.failed = true
      []
    }
  }
  self.to_client.append(down)
  self.server_events()
}

///|
/// Delivers up to `n` datagrams in flight to one end.
fn H3Pair::deliver(self : H3Pair, to_server : Bool, n : Int32) -> Unit {
  self.collect()
  let queue = if to_server { self.to_server } else { self.to_client }
  let peer = if to_server { self.server } else { self.client }
  for _ in 0..<n.min(queue.length()) {
    peer.read(queue.remove(0)) catch {
      _ => ()
    }
  }
  if to_server {
    self.server_events()
  } else {
    self.client_events()
  }
}

///|
fn H3Pair::read_all(self : H3Pair) -> Unit {
  for _, s in self.streams {
    if s.unread_up > 0 {
      self.server.consume(s.id, s.unread_up)
      s.unread_up = 0
    }
    if s.unread_down > 0 {
      self.client.consume(s.id, s.unread_down)
      s.unread_down = 0
    }
  }
}

///|
/// Runs both ends' expired timers.
fn H3Pair::timers(self : H3Pair) -> Unit {
  for conn in [self.client, self.server] {
    if conn.expiry_ms() == Some(0) {
      conn.on_expiry() catch {
        _ => ()
      }
    }
  }
}

///|
fn H3Pair::step(self : H3Pair, input : Input) -> Unit {
  match input.byte() % 10 {
    0 => {
      let body = input.byte() % 2 == 0
      let request = input.fields([
        (":method", if body { "POST" } else { "GET" }),
        (":scheme", "https"),
        (":authority", "localhost"),
        (":path", "/"),
      ])
      let id = self.client.submit_request(request, body~) catch { _ => return }
      self.streams[id] = H3Stream::{
        id,
        request,
        response: None,
        sent_up: Buffer(),
        up_open: body,
        sent_down: Buffer(),
        down_open: false,
        got_up: Buffer(),
        got_down: Buffer(),
        unread_up: 0,
        unread_down: 0,
      }
    }
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
        }
      }
    2 =>
      if !self.unanswered.is_empty() {
        let id = self.unanswered.remove(0)
        guard self.streams.get(id) is Some(s) else { return }
        let body = input.byte() % 2 == 0
        let response = input.fields([
          (":status", (200 + input.byte() % 400).to_string()),
        ])
        self.server.submit_response(id, response, body~) catch {
          _ => return
        }
        s.response = Some(response)
        s.down_open = body
      }
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
        }
      }
    4 =>
      if self.stream_at(input.byte()) is Some(s) {
        let conn = if input.byte() % 2 == 0 { self.client } else { self.server }
        let code = 0x100L + (input.byte() % 16).to_int64()
        conn.reset(s.id, code, read_only=input.byte() % 3 == 0)
        s.up_open = false
        s.down_open = false
      }
    5 => self.deliver(true, input.byte() % 4 + 1)
    6 => self.deliver(false, input.byte() % 4 + 1)
    7 => self.read_all()
    8 => self.timers()
    // A datagram of the fuzzer's own, to either end.
    _ => {
      let to_server = input.byte() % 2 == 0
      let datagram = input.bytes(input.byte() * 6)
      let conn = if to_server { self.server } else { self.client }
      conn.read(datagram) catch {
        _ => ()
      }
      if to_server {
        self.server_events()
      } else {
        self.client_events()
      }
    }
  }
}

///|
pub fn fuzz_h3_pair(data : Bytes) -> Int32 {
  let input = Input::new(data)
  let mode = input.byte()
  let (client_quic, server_quic) = contexts_once()
  let settings = @h3.H3Settings::default()
  let settings = if (mode & 1) != 0 {
    {
      ..settings,
      stream_window: 64,
      connection_window: 256,
      low_mark: 32,
      max_header_list: 200,
    }
  } else {
    settings
  }
  let client = @h3.QuicConn::client(
    client_quic,
    host="localhost",
    local_address="127.0.0.1:50000",
    remote_address="127.0.0.1:4433",
    settings~,
  ) catch {
    _ => abort("no client connection")
  }
  defer client.free()
  let first = client.datagrams() catch { _ => abort("no client Initial") }
  let server = @h3.QuicConn::server(
    server_quic,
    first[0],
    local_address="127.0.0.1:4433",
    remote_address="127.0.0.1:50000",
    settings~,
  ) catch {
    _ => abort("the server refused the client's Initial")
  }
  defer server.free()
  let pair : H3Pair = {
    client,
    server,
    streams: Map([]),
    unanswered: [],
    to_server: first,
    to_client: [],
    failed: false,
  }
  // The handshake, then the program.
  for _ in 0..<50 {
    if client.handshake_done() && server.handshake_done() {
      break
    }
    pair.deliver(true, 16)
    pair.deliver(false, 16)
  }
  if !client.handshake_done() || !server.handshake_done() {
    abort("the in-memory handshake did not complete")
  }
  for steps = 0; steps < 300 && !input.done() && !pair.failed; steps = steps + 1 {
    pair.step(input)
  }
  // What is in flight goes over, so the last steps' bytes are checked too.
  for _ in 0..<50 {
    if pair.failed {
      break
    }
    pair.read_all()
    pair.deliver(true, 64)
    pair.deliver(false, 64)
  }
  0
}

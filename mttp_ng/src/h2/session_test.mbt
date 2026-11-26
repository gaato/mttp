// A client and a server session joined in memory: each step hands one
// side's output to the other until neither has anything to say.

///|
/// The events of both sides after the bytes in flight settled.
priv struct Pair {
  client : @h2.H2Session
  server : @h2.H2Session
  client_events : Array[@h2.H2Event]
  server_events : Array[@h2.H2Event]
}

///|
fn pair(
  client~ : @h2.H2Settings = @h2.H2Settings::client(),
  server~ : @h2.H2Settings = @h2.H2Settings::server(),
) -> Pair raise {
  let pair = {
    client: @h2.H2Session::client(settings=client),
    server: @h2.H2Session::server(settings=server),
    client_events: [],
    server_events: [],
  }
  pair.settle()
  pair.take()
  pair
}

///|
/// Moves output both ways until both sides are quiet.
fn Pair::settle(self : Pair) -> Unit raise {
  for _ in 0..<100 {
    let to_server = self.client.output()
    let to_client = self.server.output()
    if to_server.length() == 0 && to_client.length() == 0 {
      return
    }
    if to_server.length() > 0 {
      self.server.recv(to_server)
    }
    self.server_events.append(self.server.events())
    if to_client.length() > 0 {
      self.client.recv(to_client)
    }
    self.client_events.append(self.client.events())
  }
  fail("the sessions never settled")
}

///|
/// Clears the events gathered so far.
fn Pair::take(self : Pair) -> Unit {
  self.client_events.clear()
  self.server_events.clear()
}

///|
fn request(path~ : String = "/") -> Array[(String, String)] {
  [
    (":method", "GET"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", path),
  ]
}

///|
fn post() -> Array[(String, String)] {
  [
    (":method", "POST"),
    (":scheme", "https"),
    (":authority", "example.com"),
    (":path", "/up"),
  ]
}

///|
/// The body bytes `events` carry for `stream`.
fn body_of(events : Array[@h2.H2Event], stream : Int32) -> Bytes {
  let out = Buffer()
  for event in events {
    if event is Data(stream=s, data) && s == stream {
      out.write_bytes(data)
    }
  }
  out.to_bytes()
}

///|
test "a GET and its response, with the frames each side sent" {
  let p = pair()
  let stream = p.client.submit_request(
    [..request(path="/hello"), ("accept", "text/plain")],
    body=false,
  )
  assert_eq(stream, 1)
  p.settle()
  assert_true(
    p.server_events.contains(
      Headers(
        stream~,
        kind=Request,
        fields=[..request(path="/hello"), ("accept", "text/plain")],
        end_stream=true,
      ),
    ),
  )
  assert_true(p.client_events.contains(Sent(stream~, end_stream=true)))
  p.take()
  p.server.submit_response(
    stream,
    [(":status", "200"), ("content-type", "text/plain")],
    body=true,
  )
  p.server.push(stream, b"hello", end=true)
  p.settle()
  assert_true(
    p.client_events.contains(
      Headers(
        stream~,
        kind=Response,
        fields=[(":status", "200"), ("content-type", "text/plain")],
        end_stream=false,
      ),
    ),
  )
  assert_eq(body_of(p.client_events, stream), b"hello")
  assert_true(p.client_events.contains(EndStream(stream~)))
  assert_true(p.client_events.contains(Closed(stream~, code=NoError)))
  assert_true(p.server_events.contains(Closed(stream~, code=NoError)))
}

///|
test "the peer's SETTINGS arrive with its stream limit" {
  let client = @h2.H2Session::client()
  let server = @h2.H2Session::server(settings={
    ..@h2.H2Settings::server(),
    max_concurrent_streams: 7,
  })
  // nghttp2's assumption until the peer says otherwise.
  assert_eq(client.peer_max_streams(), 100)
  server.recv(client.output())
  client.recv(server.output())
  assert_true(client.events().contains(Settings(max_concurrent_streams=7)))
  assert_eq(client.peer_max_streams(), 7)
}

///|
test "a body waits for its window, which only the reader opens" {
  let window = 65535
  let p = pair(server={ ..@h2.H2Settings::server(), stream_window: window, })
  let stream = p.client.submit_request(post(), body=true)
  let big = Bytes::makei(200000, i => (i % 251).to_byte())
  p.client.push(stream, big, end=true)
  p.settle()
  let first = body_of(p.server_events, stream)
  // No more than the stream window before the server takes anything.
  assert_eq(first.length(), window)
  assert_eq(p.client.queued(stream), Some(big.length() - window))
  // Taking it into the connection's buffers opens only the connection.
  p.server.consume_connection(first.length())
  p.take()
  p.settle()
  assert_eq(body_of(p.server_events, stream).length(), 0)
  // The reader taking it opens the stream.
  let received = Buffer()
  received.write_bytes(first)
  while received.length() < big.length() {
    p.server.consume_stream(stream, window)
    p.server.consume_connection(window)
    p.take()
    p.settle()
    let more = body_of(p.server_events, stream)
    guard more.length() > 0 else { fail("the body stalled") }
    received.write_bytes(more)
  }
  assert_true(received.to_bytes() == big)
  assert_true(p.server_events.contains(EndStream(stream~)))
}

///|
test "a body queue below the low mark says so once per push" {
  let p = pair()
  let stream = p.client.submit_request(post(), body=true)
  p.client.push(stream, Bytes::make(40000, b'x'), end=false)
  p.settle()
  let drained = p.client_events.filter(e => e is Drained(..))
  assert_eq(drained, [Drained(stream~)])
  assert_eq(p.client.queued(stream), Some(0))
  let first = body_of(p.server_events, stream).length()
  p.take()
  p.client.push(stream, b"end", end=true)
  p.settle()
  // The last push ended the body: nothing more to wait for, and nothing
  // more is taken.
  assert_eq(p.client_events.filter(e => e is Drained(..)), [])
  assert_eq(p.client.queued(stream), Some(0))
  try p.client.push(stream, b"more", end=true) catch {
    @h2.H2Error(..) => ()
  } noraise {
    _ => fail("an ended body took more bytes")
  }
  assert_eq(first + body_of(p.server_events, stream).length(), 40003)
}

///|
test "a reset reaches the other side with its code" {
  let p = pair()
  let stream = p.client.submit_request(request(), body=false)
  p.settle()
  p.take()
  p.server.reset(stream, RefusedStream)
  p.settle()
  assert_true(p.client_events.contains(Closed(stream~, code=RefusedStream)))
  try p.server.push(stream, b"late", end=true) catch {
    @h2.H2Error(..) => ()
  } noraise {
    _ => fail("a closed stream took body bytes")
  }
}

///|
test "GOAWAY names the last stream processed, and no stream opens after it" {
  let p = pair()
  let first = p.client.submit_request(request(), body=false)
  p.settle()
  p.take()
  p.server.goaway(NoError)
  p.settle()
  assert_true(p.client_events.contains(GoAway(last_stream=first, code=NoError)))
  assert_false(p.client.can_open())
  try p.client.submit_request(request(), body=false) catch {
    @h2.H2Error(..) => ()
  } noraise {
    _ => fail("a request was submitted after GOAWAY")
  }
}

///|
test "a graceful shutdown lets streams in flight start" {
  let p = pair()
  p.server.shutdown_notice()
  p.settle()
  assert_true(
    p.client_events.contains(GoAway(last_stream=0x7fffffff, code=NoError)),
  )
}

///|
test "a header block over the limit resets its stream" {
  let p = pair(server={ ..@h2.H2Settings::server(), max_header_list: 200, })
  let stream = p.client.submit_request(
    [..request(), ("x-big", "v".repeat(300))],
    body=false,
  )
  p.settle()
  assert_true(p.server_events.contains(TooLarge(stream~)))
  assert_false(p.server_events.any(e => e is Headers(..)))
  assert_true(p.client_events.contains(Closed(stream~, code=InternalError)))
}

///|
test "bytes that are not HTTP/2 fail the session, which answers with GOAWAY" {
  let server = @h2.H2Session::server()
  try server.recv(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n") catch {
    @h2.H2Error(code~, ..) => assert_true(code < 0)
  } noraise {
    _ => fail("an HTTP/1.1 request passed as HTTP/2")
  }
  // nghttp2 queues GOAWAY(PROTOCOL_ERROR) after its SETTINGS.
  assert_true(server.output().length() > 0)
}

///|
test "a header field must be octets" {
  let client = @h2.H2Session::client()
  try
    client.submit_request([..request(), ("x-name", "日本")], body=false)
  catch {
    @h2.H2Error(..) => ()
  } noraise {
    _ => fail("a character above U+00FF was submitted")
  }
}

///|
test "a PING is acknowledged" {
  let p = pair()
  p.client.ping()
  p.settle()
  assert_true(p.client_events.contains(PingAck))
}

///|
/// A request with `n` fields of `size` bytes each after its pseudo-fields.
fn big_request(n : Int32, size : Int32) -> Array[(String, String)] {
  let fields = request()
  for i in 0..<n {
    fields.push(("x-field-\{i}", String::make(size, 'a')))
  }
  fields
}

///|
test "a header block read across two drains of events keeps every field" {
  let p = pair()
  // Larger than a frame: HEADERS and CONTINUATION.
  let fields = big_request(40, 600)
  let stream = p.client.submit_request(fields, body=false)
  let bytes = p.client.output()
  let half = bytes.length() / 2
  p.server.recv(bytes[:half].to_owned())
  let first = p.server.events()
  assert_false(first.iter().any(e => e is Headers(..)))
  p.server.recv(bytes[half:].to_owned())
  let second = p.server.events()
  assert_true(
    second.contains(Headers(stream~, kind=Request, fields~, end_stream=true)),
  )
}

///|
/// RFC 9113, section 8.2.1: a field with a character a field may not hold
/// makes the message malformed, a stream error (section 8.1.1). nghttp2
/// would drop such a field and pass the rest on; the session resets the
/// stream instead (found by fuzz_ng's HTTP/2 pair).
test "a request with an invalid field is reset, not passed on without it" {
  for field in [("\u{10}a", "1"), ("x", "a\u{00}b"), ("x", "a\u{01}b")] {
    let p = pair()
    let stream = p.client.submit_request([..request(), field], body=false)
    p.settle()
    assert_false(p.server_events.iter().any(e => e is Headers(..)))
    assert_true(p.client_events.contains(Closed(stream~, code=ProtocolError)))
  }
}

///|
/// A request reset before its HEADERS went is not sent; resetting it again
/// sends nothing either: to the server the stream is idle, and RST_STREAM
/// on an idle stream is a connection error (RFC 9113, section 6.4). nghttp2
/// 1.64 sent one (found by fuzz_ng's HTTP/2 pair on Debian 13).
test "a request reset before it went out is not sent, nor reset again" {
  let p = pair()
  let stream = p.client.submit_request(request(), body=false)
  p.client.reset(stream, Cancel)
  p.settle()
  p.client.reset(stream, Cancel)
  p.settle()
  assert_false(p.server_events.iter().any(e => e is Headers(..)))
  assert_false(p.server_events.iter().any(e => e is GoAway(..)))
  assert_false(p.client_events.iter().any(e => e is GoAway(..)))
  // The connection still carries requests.
  p.take()
  let next = p.client.submit_request(request(), body=false)
  p.settle()
  assert_true(
    p.server_events.iter().any(e => e is Headers(stream=s, ..) && s == next),
  )
}

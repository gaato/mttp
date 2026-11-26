// A client and a server connection joined in memory: each step hands one
// side's datagrams to the other, and timers that expired are handled, until
// both are quiet.

///|
async fn testdata(name : String) -> String {
  for dir in ["../../testdata", "testdata", "mttp_ng/testdata"] {
    if @fs.exists("\{dir}/\{name}") {
      return @fs.realpath("\{dir}/\{name}")
    }
  }
  fail("no testdata/\{name} below the working directory")
}

///|
priv struct Pair {
  client : @h3.QuicConn
  server : @h3.QuicConn
  client_events : Array[@h3.H3Event]
  server_events : Array[@h3.H3Event]
}

///|
const CLIENT_ADDR : String = "127.0.0.1:50000"

///|
const SERVER_ADDR : String = "127.0.0.1:4433"

///|
async fn pair(settings~ : @h3.H3Settings = @h3.H3Settings::default()) -> Pair {
  let client = @h3.QuicConn::client(
    @h3.ClientQuic::new(trust=PemFile(testdata("root.pem"))),
    host="localhost",
    local_address=CLIENT_ADDR,
    remote_address=SERVER_ADDR,
  )
  let first = client.datagrams()
  assert_true(first.length() > 0)
  let quic = @h3.ServerQuic::from_pem(
    chain=@fs.read_text(testdata("localhost.pem")),
    key=@fs.read_text(testdata("localhost.key")),
  )
  let server = @h3.QuicConn::server(
    quic,
    first[0],
    local_address=SERVER_ADDR,
    remote_address=CLIENT_ADDR,
    settings~,
  )
  for datagram in first {
    server.read(datagram)
  }
  let p = { client, server, client_events: [], server_events: [], }
  p.settle()
  p
}

///|
/// Moves datagrams both ways, and handles expired timers, until neither side
/// has anything to send for a while nor a timer due within 50 ms.
async fn Pair::settle(self : Pair) -> Unit {
  let mut quiet = 0
  for _ in 0..<2000 {
    let to_server = self.client.datagrams()
    let to_client = self.server.datagrams()
    for d in to_server {
      self.server.read(d) catch {
        _ => ()
      }
    }
    for d in to_client {
      self.client.read(d) catch {
        _ => ()
      }
    }
    self.client_events.append(self.client.events())
    self.server_events.append(self.server.events())
    if to_server.is_empty() && to_client.is_empty() {
      // Quiet only when no timer is about to fire either: a delayed
      // acknowledgement (up to 25 ms) is what lets data past the initial
      // congestion window go, so a pair waiting on one has not settled.
      let soon = [self.client.expiry_ms(), self.server.expiry_ms()].any(ms => {
        ms is Some(ms) && ms < 50
      })
      if !soon {
        quiet += 1
      }
      if quiet > 3 {
        return
      }
      // Pacing or a timer: wait for whichever comes first, up to 5 ms.
      let wait = [self.client.expiry_ms(), self.server.expiry_ms()]
        .filter_map(x => x)
        .fold(init=5, (a, b) => if b < a { b } else { a })
      if wait > 0 {
        @async.sleep(wait)
      }
      if self.client.expiry_ms() == Some(0) {
        self.client.on_expiry() catch {
          _ => ()
        }
      }
      if self.server.expiry_ms() == Some(0) {
        self.server.on_expiry() catch {
          _ => ()
        }
      }
    } else {
      quiet = 0
    }
  }
  fail("the connections never settled")
}

///|
fn Pair::take(self : Pair) -> Unit {
  self.client_events.clear()
  self.server_events.clear()
}

///|
fn body_of(events : Array[@h3.H3Event], stream : Int64) -> Bytes {
  let out = Buffer()
  for event in events {
    if event is Data(stream=s, data) && s == stream {
      out.write_bytes(data)
    }
  }
  out.to_bytes()
}

///|
fn request(meth~ : String = "GET") -> Array[(String, String)] {
  [
    (":method", meth),
    (":scheme", "https"),
    (":authority", "localhost"),
    (":path", "/hello"),
  ]
}

///|
async test "a handshake, a request and its response" {
  @async.with_timeout(10000, () => {
    let p = pair()
    assert_true(p.client.handshake_done())
    assert_true(p.server.handshake_done())
    assert_true(p.client_events.contains(HandshakeDone))
    p.take()
    let stream = p.client.submit_request(request(), body=false)
    assert_eq(stream, 0L)
    p.settle()
    assert_true(
      p.server_events.contains(
        Headers(stream~, fields=request(), end_stream=true),
      ),
    )
    p.take()
    p.server.submit_response(stream, [(":status", "200")], body=true)
    p.server.push(stream, b"hello over h3", end=true)
    p.settle()
    assert_true(
      p.client_events.contains(
        Headers(stream~, fields=[(":status", "200")], end_stream=false),
      ),
    )
    assert_eq(body_of(p.client_events, stream), b"hello over h3")
    assert_true(p.client_events.contains(EndStream(stream~)))
  })
}

///|
async test "a body larger than the windows arrives as the reader takes it" {
  @async.with_timeout(20000, () => {
    let p = pair(settings={
      ..@h3.H3Settings::default(),
      stream_window: 65536,
      connection_window: 131072,
    })
    p.take()
    let stream = p.client.submit_request(request(meth="POST"), body=true)
    let big = Bytes::makei(300000, i => (i % 251).to_byte())
    p.client.push(stream, big, end=true)
    let received = Buffer()
    for _ in 0..<200 {
      p.settle()
      let got = body_of(p.server_events, stream)
      p.take()
      if got.length() > 0 {
        received.write_bytes(got)
        p.server.consume(stream, got.length())
      }
      if received.length() >= big.length() {
        break
      }
    }
    assert_true(received.to_bytes() == big)
  })
}

///|
async test "the client closes, and the server hears it" {
  @async.with_timeout(10000, () => {
    let p = pair()
    p.take()
    p.client.close()
    p.settle()
    assert_true(p.client.closed())
    assert_true(
      p.server_events.any(e => e is ConnectionClosed(by_peer=true, ..)),
    )
  })
}

///|
async test "a certificate for another name fails the handshake" {
  @async.with_timeout(10000, () => {
    let client = @h3.QuicConn::client(
      @h3.ClientQuic::new(trust=PemFile(testdata("root.pem"))),
      host="example.com",
      local_address=CLIENT_ADDR,
      remote_address=SERVER_ADDR,
    )
    let first = client.datagrams()
    let server = @h3.QuicConn::server(
      @h3.ServerQuic::from_pem(
        chain=@fs.read_text(testdata("localhost.pem")),
        key=@fs.read_text(testdata("localhost.key")),
      ),
      first[0],
      local_address=SERVER_ADDR,
      remote_address=CLIENT_ADDR,
    )
    let p = { client, server, client_events: [], server_events: [], }
    for d in first {
      server.read(d)
    }
    p.settle()
    assert_false(client.handshake_done())
    assert_true(client.closed())
  })
}

///|
async test "a header block read across drains of events keeps every field" {
  @async.with_timeout(10000, () => {
    let p = pair()
    p.take()
    // Larger than a packet: the HEADERS frame spans several datagrams.
    let fields = request()
    for i in 0..<20 {
      fields.push(("x-field-\{i}", String::make(300, 'a')))
    }
    let stream = p.client.submit_request(fields, body=false)
    let datagrams = p.client.datagrams()
    assert_true(datagrams.length() > 1)
    let drains = []
    for datagram in datagrams {
      p.server.read(datagram)
      drains.push(p.server.events())
    }
    assert_false(drains[0].iter().any(e => e is Headers(..)))
    p.settle()
    for events in drains {
      p.server_events.append(events)
    }
    assert_true(
      p.server_events.contains(Headers(stream~, fields~, end_stream=true)),
    )
  })
}

///|
test "a datagram of another QUIC version is answered with Version Negotiation" {
  // A long header packet of a reserved version (RFC 9000, section 15),
  // with a destination and a source connection ID, padded to 1200 bytes.
  let datagram = Bytes::makei(1200, i => {
    match i {
      0 => b'\xc0'
      1 => b'\x1a'
      2 => b'\x2a'
      3 => b'\x3a'
      4 => b'\x4a'
      5 => b'\x08' // DCID length
      6..<=13 => b'\x11'
      14 => b'\x04' // SCID length
      15..<=18 => b'\x22'
      _ => b'\x00'
    }
  })
  guard @h3.version_negotiation(datagram) is Some(packet) else {
    fail("no Version Negotiation")
  }
  // Version 0, the client's SCID as the DCID and its DCID as the SCID, then
  // the versions this module speaks: QUIC v1.
  assert_true(packet[0] >= b'\x80')
  assert_eq(packet[1:5].to_owned(), b"\x00\x00\x00\x00")
  assert_eq(packet[5], b'\x04')
  assert_eq(packet[6:10].to_owned(), b"\x22\x22\x22\x22")
  assert_eq(packet[10], b'\x08')
  assert_eq(packet[19:].to_owned(), b"\x00\x00\x00\x01")
  // QUIC v1 itself, and a datagram too small to start a connection, are not.
  let v1 = Bytes::makei(1200, i => if i == 4 { b'\x01' } else { datagram[i] })
  let v1 = Bytes::makei(1200, i => {
    if i >= 1 && i <= 3 {
      b'\x00'
    } else {
      v1[i]
    }
  })
  assert_true(@h3.version_negotiation(v1) is None)
  assert_true(@h3.version_negotiation(datagram[:100].to_owned()) is None)
}

///|
/// An informational head (100 Continue) goes before the response, as a
/// head of its own (RFC 9114, section 4.1).
async test "an informational head goes before the response" {
  @async.with_timeout(10000, () => {
    let p = pair()
    p.take()
    let stream = p.client.submit_request(request(), body=false)
    p.settle()
    p.take()
    p.server.submit_info(stream, [(":status", "100")])
    p.server.submit_response(stream, [(":status", "200")], body=false)
    p.settle()
    let heads = p.client_events.filter(event => event is Headers(..))
    assert_eq(heads, [
      Headers(stream~, fields=[(":status", "100")], end_stream=false),
      Headers(stream~, fields=[(":status", "200")], end_stream=true),
    ])
  })
}

///|
/// A body whose last piece and FIN are pushed at once, larger than a
/// packet, goes out over several writes; only the write that takes the
/// last byte takes the FIN (ngtcp2 encodes it only with all the data
/// offered), so `Sent` reports the end once, last (Codex's review of #58:
/// it was reported with the first write, and an exchange took its upload
/// for done).
async test "Sent reports a stream's end only with the write that took it" {
  @async.with_timeout(10000, () => {
    let p = pair()
    p.take()
    let stream = p.client.submit_request(request(meth="POST"), body=true)
    p.client.push(stream, Bytes::make(20000, b'u'), end=true)
    p.settle()
    let sent = p.client_events.filter_map(event => {
      match event {
        Sent(stream=s, end_stream~) if s == stream => Some(end_stream)
        _ => None
      }
    })
    assert_true(sent.length() > 1, msg="one write took the whole body")
    assert_eq(sent.filter(end => end).length(), 1)
    assert_eq(sent.last(), Some(true))
    assert_eq(body_of(p.server_events, stream).length(), 20000)
  })
}

///|
/// RFC 9000, section 8.1: a server that sends a Retry starts a connection
/// only for the Initial that returns its token from the address it was
/// sent to; a token from another address, or a made-up one, is answered
/// with CONNECTION_CLOSE, and the connection then completes over the token.
async test "a Retry's token starts the connection only from the address it was sent to" {
  let client = @h3.QuicConn::client(
    @h3.ClientQuic::new(trust=PemFile(testdata("root.pem"))),
    host="localhost",
    local_address=CLIENT_ADDR,
    remote_address=SERVER_ADDR,
  )
  let first = client.datagrams()
  // Without `validate`, an Initial without a token needs no answer.
  assert_eq(
    @h3.answer_initial(first[0], remote_address=CLIENT_ADDR, validate=false),
    None,
  )
  guard @h3.answer_initial(first[0], remote_address=CLIENT_ADDR, validate=true)
    is Some(retry) else {
    fail("no Retry")
  }
  // A Retry is a long header packet of type 3, and smaller than the
  // Initial it answers.
  assert_eq(retry[0].to_int() & 0xf0, 0xf0)
  assert_true(retry.length() < first[0].length())
  client.read(retry)
  let second = client.datagrams()
  assert_true(second.length() > 0)
  // The token is good for the address it was sent to only.
  guard @h3.answer_initial(
      second[0],
      remote_address="127.0.0.1:50001",
      validate=true,
    )
    is Some(close) else {
    fail("a token from another address was taken")
  }
  assert_true(close.length() < second[0].length())
  assert_eq(
    @h3.answer_initial(second[0], remote_address=CLIENT_ADDR, validate=true),
    None,
  )
  let quic = @h3.ServerQuic::from_pem(
    chain=@fs.read_text(testdata("localhost.pem")),
    key=@fs.read_text(testdata("localhost.key")),
  )
  // Without the token's original DCID and the Retry's SCID in its
  // transport parameters, the client would refuse the handshake.
  let server = @h3.QuicConn::server(
    quic,
    second[0],
    local_address=SERVER_ADDR,
    remote_address=CLIENT_ADDR,
  )
  for datagram in second {
    server.read(datagram)
  }
  let p = { client, server, client_events: [], server_events: [], }
  p.settle()
  assert_true(client.handshake_done())
  assert_true(server.handshake_done())
  assert_false(client.closed())
}

///|
/// RFC 9000, section 10.3: a Stateless Reset is smaller than the packet it
/// answers (one byte up to 43, so two endpoints cannot answer each other's
/// for ever), at least 21 bytes, and answers short header packets only.
test "a Stateless Reset is smaller than what it answers, and only for short headers" {
  let short = n => Bytes::makei(n, i => if i == 0 { b'\x40' } else { b'\x07' })
  assert_eq(@h3.stateless_reset(short(21)), None)
  assert_eq(@h3.stateless_reset(short(22)).map(b => b.length()), Some(21))
  assert_eq(@h3.stateless_reset(short(43)).map(b => b.length()), Some(42))
  assert_eq(@h3.stateless_reset(short(44)).map(b => b.length()), Some(43))
  assert_eq(@h3.stateless_reset(short(1200)).map(b => b.length()), Some(43))
  // A reset looks like a short header packet.
  assert_eq(
    @h3.stateless_reset(short(100)).map(b => b[0].to_int() & 0xc0),
    Some(0x40),
  )
  let long = Bytes::makei(1200, i => if i == 0 { b'\xc0' } else { b'\x07' })
  assert_eq(@h3.stateless_reset(long), None)
  // The ID a short header's reset is for is read at this server's length.
  assert_eq(
    @h3.destination_cid(short(30)),
    Some(Bytes::makei(17, _ => b'\x07')),
  )
}

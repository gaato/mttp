// How the HTTP/3 server keeps connections (RFC 9000, sections 8, 9 and 10):
// routing by connection ID, so a client may move; the closing period, in
// which a lost CONNECTION_CLOSE is sent again; the Stateless Reset of a
// connection the server forgot; and Retry once many handshakes are open.

///|
/// A client connection driven by hand over a UDP socket the test may swap,
/// as a NAT that rebinds does.
priv struct Raw {
  conn : @h3.QuicConn
  server : @socket.Addr
  mut udp : @socket.UdpClient
  statuses : Map[Int64, String]
  ended : Array[Int64]
  mut closed : (Bool, Int64)?
  /// The server rejected the connection's early data.
  mut rejected : Bool
}

///|
async fn Raw::open(port : Int32, resumption? : Bytes) -> Raw {
  let server = @socket.Addr::parse("127.0.0.1:\{port}")
  {
    conn: @h3.QuicConn::client(
      @h3.ClientQuic::new(trust=PemFile(testdata("root.pem"))),
      host="localhost",
      remote_address=server.to_string(),
      resumption?,
    ),
    server,
    udp: @socket.UdpClient(server),
    statuses: Map([]),
    ended: [],
    closed: None,
    rejected: false,
  }
}

///|
fn Raw::close(self : Raw) -> Unit {
  self.udp.close()
  self.conn.free()
}

///|
fn Raw::take_events(self : Raw) -> Unit {
  for event in self.conn.events() {
    match event {
      Headers(stream~, fields~, end_stream~) => {
        self.statuses[stream] = fields[0].1
        if end_stream {
          self.ended.push(stream)
        }
      }
      Data(stream~, data) => self.conn.consume(stream, data.length())
      EndStream(stream~) => self.ended.push(stream)
      ConnectionClosed(by_peer~, code~) => self.closed = Some((by_peer, code))
      EarlyDataRejected => self.rejected = true
      _ => ()
    }
  }
}

///|
/// Sends what the connection has to say, then waits for a datagram (no
/// longer than its next timer) and feeds it, or runs the timer.
async fn Raw::step(self : Raw) -> Unit {
  for datagram in (self.conn.datagrams() catch { _ => [] }) {
    self.udp.send(datagram)
  }
  self.take_events()
  let got = @async.with_timeout_opt(
    self.conn.expiry_ms().unwrap_or(50).max(1),
    () => self.udp.recv(max_len=65536),
  )
  match got {
    Some(datagram) => self.conn.read(datagram) catch { _ => () }
    None =>
      if self.conn.expiry_ms() == Some(0) {
        self.conn.on_expiry() catch {
          _ => ()
        }
      }
  }
  self.take_events()
}

///|
/// Steps until `done` or `within_ms`.
async fn Raw::drive(
  self : Raw,
  done : () -> Bool,
  within_ms~ : Int32 = 5000,
) -> Unit {
  let finished = @async.with_timeout_opt(within_ms, () => {
    while !done() {
      self.step()
    }
  })
  if finished is None {
    fail("not done within \{within_ms} ms")
  }
}

///|
/// Steps for `ms`: what is left of the handshake (its last flights and
/// their acknowledgements) is done, and the server has nothing more to
/// say until its own timers.
async fn Raw::settle(self : Raw, ms~ : Int32) -> Unit {
  ignore(
    @async.with_timeout_opt(ms, () => {
      while true {
        self.step()
      }
    }),
  )
}

///|
/// Receives the server's next datagram and drops it, as if it were lost.
async fn Raw::lose_next(self : Raw, within_ms~ : Int32) -> Unit {
  guard @async.with_timeout_opt(within_ms, () => self.udp.recv(max_len=65536))
    is Some(_) else {
    fail("nothing arrived within \{within_ms} ms")
  }
}

///|
fn Raw::get(self : Raw) -> Int64 raise {
  self.conn.submit_request(
    [
      (":method", "GET"),
      (":scheme", "https"),
      (":authority", "localhost"),
      (":path", "/hello"),
    ],
    body=false,
  )
}

///|
/// Receives and drops what arrives until `quiet_ms` pass with nothing; the
/// connection never sees it, as if it were lost.
async fn Raw::lose(self : Raw, quiet_ms~ : Int32) -> Int32 {
  let mut lost = 0
  while @async.with_timeout_opt(quiet_ms, () => self.udp.recv(max_len=65536))
        is Some(_) {
    lost += 1
  }
  lost
}

///|
/// A NAT that rebinds gives the client another port mid-connection: the
/// server finds the connection by its ID, validates the new path and
/// answers there (RFC 9000, section 9). Routed by the client's address, as
/// first written, the datagrams from the new port were dropped.
async test "a client whose address changes keeps its connection" {
  with_server(port => {
    let raw = Raw::open(port)
    defer raw.close()
    raw.drive(() => raw.conn.handshake_done())
    let first = raw.get()
    raw.drive(() => raw.ended.contains(first))
    assert_eq(raw.statuses.get(first), Some("200"))
    // The same connection, from another port.
    raw.udp.close()
    raw.udp = @socket.UdpClient(raw.server)
    let second = raw.get()
    raw.drive(() => raw.ended.contains(second))
    assert_eq(raw.statuses.get(second), Some("200"))
    assert_eq(raw.closed, None)
  })
}

///|
/// The server closes a connection with no request after
/// `header_timeout_ms`, and its CONNECTION_CLOSE is lost: in the closing
/// period the server sends it again when the client's next packet comes
/// (RFC 9000, section 10.2.1), so the client learns why at once, by the
/// close's own code. Freed at once, as first written, the server answered
/// nothing, and the client waited out its idle timeout. Only the address
/// the connection had gets it again (Codex's review of #59).
async test "a CONNECTION_CLOSE that was lost is sent again in the closing period" {
  with_server(
    limits={ ..@h1server.ServerLimits::default(), header_timeout_ms: 300, },
    port => {
      let raw = Raw::open(port)
      defer raw.close()
      raw.drive(() => raw.conn.handshake_done())
      raw.settle(ms=100)
      // The next datagram is the close, at 300 ms; it is lost. The closing
      // period is three probe timeouts, under 100 ms on a loopback, so
      // the probes below follow it at once.
      raw.lose_next(within_ms=1000)
      // A packet of the connection from another address gets nothing: a
      // connection ID proves nothing of who sends, and answering would
      // reflect the close at whoever the source names.
      let first = raw.udp
      raw.udp = @socket.UdpClient(raw.server)
      ignore(raw.get())
      for datagram in raw.conn.datagrams() {
        raw.udp.send(datagram)
      }
      assert_eq(raw.lose(quiet_ms=20), 0)
      raw.udp.close()
      raw.udp = first
      ignore(raw.get())
      raw.drive(() => raw.closed is Some(_), within_ms=2000)
      assert_eq(raw.closed, Some((true, @h3.H3_NO_ERROR)))
    },
  )
}

///|
/// Once the closing period is over the server keeps nothing of the
/// connection, and a packet for it gets a Stateless Reset (RFC 9000,
/// section 10.3), which the client knows by the token the server gave with
/// the connection ID: it closes at once instead of waiting out its idle
/// timeout, and not with the close's code. Without the reset, the server
/// dropped the packet.
async test "a packet for a connection the server forgot gets a Stateless Reset" {
  with_server(
    limits={ ..@h1server.ServerLimits::default(), header_timeout_ms: 300, },
    port => {
      let raw = Raw::open(port)
      defer raw.close()
      raw.drive(() => raw.conn.handshake_done())
      raw.settle(ms=100)
      raw.lose_next(within_ms=1000)
      // Three probe timeouts on a loopback are well under a second.
      @async.sleep(1000)
      ignore(raw.get())
      raw.drive(() => raw.closed is Some(_), within_ms=2000)
      guard raw.closed is Some((by_peer, code)) else { fail("not closed") }
      assert_true(by_peer)
      assert_true(
        code != @h3.H3_NO_ERROR,
        msg="the close was sent, not a reset",
      )
    },
  )
}

///|
/// Initials that are never followed up (a flood from forged addresses
/// looks so to the server) held a `max_connections` slot each until their
/// handshakes timed out, and a real client found the server full. Once a
/// quarter of the slots hold open handshakes, a new client first gets a
/// Retry (RFC 9000, section 8.1.2): a silent one never answers it and holds
/// nothing, and a real one answers and is served.
async test "Initials never followed up do not fill the server: Retry under load" {
  with_server(
    limits={ ..@h1server.ServerLimits::default(), max_connections: 4, },
    port => {
      let server = @socket.Addr::parse("127.0.0.1:\{port}")
      let silent = []
      defer (for s in silent {
        let (udp, conn) : (@socket.UdpClient, @h3.QuicConn) = s
        udp.close()
        conn.free()
      })
      let answers = []
      for i in 0..<6 {
        let udp = @socket.UdpClient(server)
        let conn = @h3.QuicConn::client(
          @h3.ClientQuic::new(trust=PemFile(testdata("root.pem"))),
          host="localhost",
          remote_address=server.to_string(),
        )
        silent.push((udp, conn))
        for datagram in conn.datagrams() {
          udp.send(datagram)
        }
        // The first gets the server's handshake; the others (one open
        // handshake is a quarter of four) a Retry, a long header packet of
        // type 3.
        guard @async.with_timeout_opt(1000, () => udp.recv(max_len=65536))
          is Some(answer) else {
          fail("client \{i} got no answer")
        }
        answers.push((answer[0].to_int() & 0xf0) == 0xf0)
      }
      assert_eq(answers, [false, true, true, true, true, true])
      // A real client answers its Retry and is served.
      let backend = client()
      defer backend.close()
      let response = backend.send(
        @mttp_core.Request::get("https://localhost:\{port}/hello"),
        defaults,
      )
      assert_eq(response.status, 200)
      ignore(text(response))
    },
  )
}

///|
/// RFC 9000, section 8: until a client's address is validated, a server
/// sends it at most three times what it received, so a forged source
/// address cannot turn the server on a victim. A client that sends its
/// first Initials (2400 bytes) and then nothing gets the handshake and one
/// probe (5790 bytes on openSUSE), and nothing more: without the limit,
/// probes would follow about 1, 3 and 7 seconds in, over 7200 bytes. A
/// token passed to ngtcp2 is taken as the address validated, which lifts
/// the limit, so only a verified Retry token is passed.
async test "an address not yet validated gets at most three times what it sent" {
  with_server(port => {
    let server = @socket.Addr::parse("127.0.0.1:\{port}")
    let udp = @socket.UdpClient(server)
    defer udp.close()
    let conn = @h3.QuicConn::client(
      @h3.ClientQuic::new(trust=PemFile(testdata("root.pem"))),
      host="localhost",
      remote_address=server.to_string(),
    )
    defer conn.free()
    let mut sent = 0
    for datagram in conn.datagrams() {
      sent += datagram.length()
      udp.send(datagram)
    }
    // The server probes on its probe timeout (about a second at first,
    // then doubling) until the limit stops it; 7.5 s cover three probes.
    let mut received = 0
    let mut datagrams = 0
    while @async.with_timeout_opt(7500, () => udp.recv(max_len=65536))
          is Some(datagram) {
      received += datagram.length()
      datagrams += 1
    }
    assert_true(datagrams > 1, msg="nothing was retransmitted")
    assert_true(
      received <= 3 * sent,
      msg="\{received} bytes sent to an address that sent \{sent}",
    )
  })
}

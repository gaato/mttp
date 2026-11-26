// 0-RTT (RFC 9001, section 4.6; RFC 8470): session tickets, early requests,
// what a server does with those that may not be repeated, and what a client
// does when its early data is rejected.

///|
fn zero_rtt(meth : String) -> Array[(String, String)] {
  [
    (":method", meth),
    (":scheme", "https"),
    (":authority", "localhost"),
    (":path", "/zero-rtt"),
  ]
}

///|
/// A resumed backend sends a GET at once, in 0-RTT, and the handler sees it
/// marked so; a POST, which a replay could repeat, waits for the handshake.
async test "a resumed backend sends a GET in 0-RTT; a POST waits for the handshake" {
  with_server(early_data=true, port => {
    // Each connection retires once its request ended, so each send
    // dials, resuming with the ticket of the one before.
    let b = @h3client.H3Backend::new(
      trust=PemFile(testdata("root.pem")),
      early_data=true,
      max_connection_age_ms=1,
    )
    defer b.close()
    let url = "https://localhost:\{port}/zero-rtt"
    let answers = []
    // The first send makes a full handshake; the POST resumes but waits
    // for the handshake; the GET after it goes in 0-RTT.
    for meth in [@mttp_core.Method::Get, Post, Get] {
      let request = @mttp_core.Request::new(meth, url)
      let request = if meth is Post {
        { ..request, body: Bytes(b"x"), }
      } else {
        request
      }
      answers.push(text(b.send(request, defaults)))
      @async.sleep(50)
    }
    assert_eq(answers, ["early=false", "early=false", "early=true"])
  })
}

///|
/// A handler may answer even a GET 425 Too Early when it came in early
/// data; the backend sends it again after the handshake (RFC 8470, section
/// 4.2), and the caller gets that answer.
async test "a 425 to a request in early data is sent again after the handshake" {
  with_server(early_data=true, port => {
    let b = @h3client.H3Backend::new(
      trust=PemFile(testdata("root.pem")),
      early_data=true,
      max_connection_age_ms=1,
    )
    defer b.close()
    let url = "https://localhost:\{port}/too-early"
    for _ in 0..<2 {
      let response = b.send(@mttp_core.Request::get(url), defaults)
      assert_eq(response.status, 200)
      assert_eq(text(response), "after the handshake")
      @async.sleep(50)
    }
  })
}

///|
/// A server that restarted has other ticket keys: it cannot read the
/// ticket, makes a full handshake and rejects the early data. The backend
/// sends the request again after the handshake, and it is answered.
async test "early data a restarted server rejects is sent again after the handshake" {
  let b = @h3client.H3Backend::new(
    trust=PemFile(testdata("root.pem")),
    early_data=true,
    max_connection_age_ms=1,
  )
  defer b.close()
  let port = Ref(0)
  with_server(early_data=true, p => {
    port.val = p
    let url = "https://localhost:\{p}/zero-rtt"
    assert_eq(
      text(b.send(@mttp_core.Request::get(url), defaults)),
      "early=false",
    )
    @async.sleep(50)
  })
  with_server(early_data=true, addr="127.0.0.1:\{port.val}", p => {
    let url = "https://localhost:\{p}/zero-rtt"
    let response = b.send(@mttp_core.Request::get(url), defaults)
    assert_eq(response.status, 200)
    assert_eq(text(response), "early=false")
  })
}

///|
/// A ticket from a first connection, for the raw connections below.
async fn ticket_of(port : Int32) -> Bytes {
  let raw = Raw::open(port)
  defer raw.close()
  raw.drive(() => raw.conn.handshake_done())
  let stream = raw.get()
  raw.drive(() => raw.ended.contains(stream))
  raw.settle(ms=100)
  guard raw.conn.resumption() is Some(resumption) else { fail("no ticket") }
  resumption
}

///|
/// A request of a method that is not safe, in early data, is answered 425
/// Too Early, not given to the handler (RFC 8470, section 5.2): a replay
/// of it would repeat its effect.
async test "a POST in early data is answered 425 Too Early" {
  with_server(early_data=true, port => {
    let ticket = ticket_of(port)
    let raw = Raw::open(port, resumption=ticket)
    defer raw.close()
    assert_true(raw.conn.early(), msg="the ticket allows no early data")
    let stream = raw.conn.submit_request(zero_rtt("POST"), body=false)
    raw.drive(() => raw.ended.contains(stream))
    assert_false(raw.rejected)
    assert_eq(raw.statuses.get(stream), Some("425"))
  })
}

///|
/// A ticket is taken once (OpenSSL's replay protection): its early data
/// is accepted the first time and rejected the second, which is how a
/// replay of a connection's early data looks to the server.
async test "a ticket's early data is accepted once, and a replay is rejected" {
  with_server(early_data=true, port => {
    let ticket = ticket_of(port)
    let first = Raw::open(port, resumption=ticket)
    defer first.close()
    let stream = first.conn.submit_request(zero_rtt("GET"), body=false)
    first.drive(() => first.ended.contains(stream))
    assert_false(first.rejected)
    assert_eq(first.statuses.get(stream), Some("200"))
    let replay = Raw::open(port, resumption=ticket)
    defer replay.close()
    assert_true(replay.conn.early())
    ignore(replay.conn.submit_request(zero_rtt("GET"), body=false))
    replay.drive(() => replay.rejected || replay.closed is Some(_))
    assert_true(replay.rejected)
  })
}

///|
/// The request sent again after a 425 stays within the attempt it began
/// in: two 600 ms answers do not fit a 1000 ms deadline (Codex's review of
/// #61). As first written it took a fresh deadline, and, each connection
/// retiring at once here, went early again on the next resumed one, got
/// 425 again, and never ended.
async test "a request sent again after a 425 keeps its attempt's deadline" {
  with_server(early_data=true, port => {
    let b = @h3client.H3Backend::new(
      trust=PemFile(testdata("root.pem")),
      early_data=true,
      max_connection_age_ms=1,
    )
    defer b.close()
    // A ticket first.
    ignore(
      text(
        b.send(
          @mttp_core.Request::get("https://localhost:\{port}/zero-rtt"),
          defaults,
        ),
      ),
    )
    @async.sleep(50)
    let failed = try
      b.send(
        @mttp_core.Request::get("https://localhost:\{port}/too-early-slow"),
        { ..defaults, timeout_ms: Some(1000), },
      )
    catch {
      @mttp_core.TransportError(kind=Timeout(..), ..) => true
      _ => false
    } noraise {
      response => {
        response.close()
        false
      }
    }
    assert_true(failed, msg="the resend outlived its attempt's deadline")
  })
}

///|
/// A request sent again after a 425 goes after a handshake, never in early
/// data again (RFC 8470, section 4.2): with every connection retiring at
/// once, so that each send resumes anew, it is answered after its second
/// send rather than 425 for ever.
async test "a request sent again after a 425 does not go early again" {
  with_server(early_data=true, port => {
    let b = @h3client.H3Backend::new(
      trust=PemFile(testdata("root.pem")),
      early_data=true,
      max_connection_age_ms=1,
    )
    defer b.close()
    ignore(
      text(
        b.send(
          @mttp_core.Request::get("https://localhost:\{port}/zero-rtt"),
          defaults,
        ),
      ),
    )
    @async.sleep(50)
    let response = @async.with_timeout(5000, () => {
      b.send(
        @mttp_core.Request::get("https://localhost:\{port}/too-early-slow"),
        defaults,
      )
    })
    assert_eq(response.status, 200)
    assert_eq(text(response), "after the handshake")
  })
}

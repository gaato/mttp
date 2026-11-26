// A bound of h3_stub.c that only the C side can show: the memory a
// stream's body queue holds, which is what is queued and what is in flight
// until the peer acknowledges it.

///|
#borrow(raw)
extern "C" fn queue_held(raw : Raw, stream : Int64) -> Int64 = "mttp_ng_h3_queue_held"

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
/// Moves datagrams between `client` and `server` until both are quiet,
/// running their timers (pacing, acknowledgement delay) as they expire;
/// `on_server` sees the server's events.
async fn exchange(
  client : QuicConn,
  server : QuicConn,
  on_server : (H3Event) -> Unit,
) -> Unit {
  let mut quiet = 0
  for _ in 0..<1000 {
    let up = client.datagrams()
    let down = server.datagrams()
    for d in up {
      server.read(d) catch {
        _ => ()
      }
    }
    for d in down {
      client.read(d) catch {
        _ => ()
      }
    }
    server.events().each(on_server)
    ignore(client.events())
    if up.is_empty() && down.is_empty() {
      quiet += 1
      if quiet > 2 {
        return
      }
      let wait = [client.expiry_ms(), server.expiry_ms()]
        .filter_map(x => x)
        .fold(init=5, (a, b) => if b < a { b } else { a })
      if wait > 0 {
        @async.sleep(wait)
      }
      for conn in [client, server] {
        if conn.expiry_ms() == Some(0) {
          conn.on_expiry() catch {
            _ => ()
          }
        }
      }
    } else {
      quiet = 0
    }
  }
}

///|
/// A long upload through a small window: the queue holds what is queued
/// (the uploader waits past 64 KiB) and what is in flight (the window), not
/// everything that went through it, since chunks are freed as the server
/// acknowledges them.
async test "a long body's queue holds what is queued and in flight, no more" {
  @async.with_timeout(30000, () => {
    let client = QuicConn::client(
      ClientQuic::new(trust=PemFile(testdata("root.pem"))),
      host="localhost",
      local_address="127.0.0.1:50000",
      remote_address="127.0.0.1:4433",
    )
    defer client.free()
    let first = client.datagrams()
    let server = QuicConn::server(
      ServerQuic::from_pem(
        chain=@fs.read_text(testdata("localhost.pem")),
        key=@fs.read_text(testdata("localhost.key")),
      ),
      first[0],
      local_address="127.0.0.1:4433",
      remote_address="127.0.0.1:50000",
      settings={ ..H3Settings::default(), stream_window: 20000, },
    )
    defer server.free()
    for d in first {
      server.read(d)
    }
    let taken = (event : H3Event) => {
      if event is Data(stream~, data) {
        server.consume(stream, data.length())
      }
    }
    exchange(client, server, taken)
    let stream = client.submit_request(
      [
        (":method", "POST"),
        (":scheme", "https"),
        (":authority", "localhost"),
        (":path", "/"),
      ],
      body=true,
    )
    let piece = Bytes::make(10000, b'b')
    let mut received = 0
    let mut most = 0L
    let count = (event : H3Event) => {
      if event is Data(stream~, data) {
        received += data.length()
        server.consume(stream, data.length())
      }
    }
    for _ in 0..<300 {
      // The uploader's backpressure: no more than 64 KiB waits unsent.
      if client.queued(stream).unwrap_or(0) < 65536 {
        client.push(stream, piece, end=false)
      }
      exchange(client, server, count)
      let held = queue_held(client.raw, stream)
      if held > most {
        most = held
      }
    }
    assert_true(received >= 2000000, msg="only \{received} bytes arrived")
    // Queued (under 64 KiB, plus the piece that crossed it) and in flight
    // (the stream window of 20000 bytes).
    assert_true(most <= 65536L + 10000L + 20000L, msg="held \{most} bytes")
  })
}

///|
/// A connection that reads its script and accepts `open_writes` writes;
/// later writes wait until the connection is closed, as a full socket
/// buffer would.
priv struct GatedConn {
  inner : @sim.ScriptedConn
  closed : &@rt.Signal
  mut open_writes : Int32
  writes : Array[Bytes]
}

///|
impl @rt.Conn for GatedConn with fn read(self, max_len~) {
  self.inner.read(max_len~)
}

///|
impl @rt.Conn for GatedConn with fn write(self, bytes) {
  if self.open_writes <= 0 {
    self.closed.wait()
    raise @mttp.TransportError(kind=Network, phase=Write, detail="closed")
  }
  self.open_writes -= 1
  self.writes.push(bytes)
}

///|
impl @rt.Conn for GatedConn with fn close(self) {
  self.inner.close()
  self.closed.notify()
}

///|
test "an early final response stops a large in-memory upload" {
  let h = Harness::new()
  let inner = @sim.ScriptedConn::new([Chunk(ok("no!", status=413))])
  let conn = GatedConn::{
    inner,
    closed: h.coordination.signal(),
    open_writes: 1,
    writes: [],
  }
  h.dialer.queue.push(Hand(conn))
  h.run(() => {
    let request = @mttp.Request::post("http://example.test/").body_bytes(
      Bytes::make(1 << 20, b'x'),
    )
    let response = h.client.send(request, exchange())
    assert_eq(response.status, 413)
    assert_eq(body_of(response), b"no!")
    // Only the first 64 KiB went out, and the connection is not reused.
    assert_eq(conn.writes.map(w => w.length()), [65536])
    assert_eq(inner.closes(), 1)
    assert_eq(h.client.idle_connections(), 0)
    h.finish()
  })
}

///|
test "informational heads neither end an upload nor start the head limit" {
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    read_timeout_ms: Some(20),
  })
  let peer = h.peer()
  h.run(() => {
    let feed = @sim.Feed::new(h.driver, [Chunk(b"x"), Wait(50), Chunk(b"y")])
    let server = h.driver.spawn(() => {
      let decoder = @h1.HeadDecoder::new()
      for ;; {
        let result = decoder.feed(peer.conn.read(max_len=65536).unwrap())
        if result.head is Some(_) {
          break
        }
      }
      peer.respond(
        b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nlink: </a>\r\n\r\n",
      )
      // Wait for the rest of the body before the final answer.
      let rest = Buffer()
      while !rest.to_bytes().has_suffix(b"0\r\n\r\n") {
        rest.write_bytes(peer.conn.read(max_len=65536).unwrap())
      }
      peer.respond(b"HTTP/1.1 204 No Content\r\n\r\n")
      ignore(peer.request())
    })
    let response = h.client.send(
      @mttp.Request::post("http://example.test/").body_stream(feed),
      exchange(),
    )
    assert_eq(response.status, 204)
    assert_eq(h.driver.now(), 50L)
    assert_eq(feed.closes(), 1)
    // The upload finished before the final head: reusable.
    assert_eq(h.client.idle_connections(), 1)
    h.finish()
    ignore(server.wait())
  })
}

///|
test "a slow upload producer is bounded by the write limit" {
  let h = Harness::new(config={
    ..@h1client.ClientConfig::default(),
    write_timeout_ms: Some(20),
  })
  let conn = h.scripted([Wait(h.coordination.signal())])
  h.run(() => {
    let feed = @sim.Feed::new(h.driver, [Chunk(b"x"), Wait(50), Chunk(b"y")])
    assert_eq(
      failing(() => {
        ignore(
          h.client.send(
            @mttp.Request::post("http://example.test/").body_stream(feed),
            exchange(),
          ),
        )
      }),
      (Timeout(ms=20), Write),
    )
    assert_eq(h.driver.now(), 20L)
    assert_eq(feed.closes(), 1)
    assert_eq(conn.closes(), 1)
    h.finish()
  })
}

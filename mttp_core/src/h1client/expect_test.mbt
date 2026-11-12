// `Expect: 100-continue`: the head goes out alone, and the body after the
// server's 100, or after a second without an answer. The interop suite
// found the need: sending the body at once to Apache over TLS, which
// refuses it with 413 and closes, lost the 413 to the reset that followed.

///|
/// A scripted connection that records its writes and notifies `body` once
/// anything follows the head.
priv struct RecordingConn {
  inner : @sim.ScriptedConn
  writes : Array[Bytes]
  body : &@rt.Signal
}

///|
impl @rt.Conn for RecordingConn with fn read(self, max_len~) {
  self.inner.read(max_len~)
}

///|
impl @rt.Conn for RecordingConn with fn write(self, bytes) {
  self.writes.push(bytes)
  if self.writes.length() > 1 {
    self.body.notify()
  }
}

///|
impl @rt.Conn for RecordingConn with fn close(self) {
  self.inner.close()
}

///|
/// Prepares the next dial: `script` built with the signal that body bytes
/// were written.
fn recording(
  h : Harness,
  script : (&@rt.Signal) -> Array[@sim.ReadStep],
) -> RecordingConn {
  let body = h.coordination.signal()
  let inner = @sim.ScriptedConn::new(script(body))
  let conn = { inner, writes: [], body, }
  h.dialer.queue.push(Hand(conn))
  h.closes.push(() => inner.closes())
  conn
}

///|
fn expecting(payload : Bytes) -> @mttp_core.Request {
  @mttp_core.Request::post("http://example.test/")
  .body_bytes(payload)
  .header("Expect", "100-continue")
}

///|
/// The writes after the head, joined.
fn body_written(conn : RecordingConn) -> Bytes {
  let out = Buffer()
  for bytes in conn.writes[1:] {
    out.write_bytes(bytes)
  }
  out.to_bytes()
}

///|
test "an expecting request sends its body after the 100" {
  let h = Harness::new()
  let conn = recording(h, body => {
    [Chunk(b"HTTP/1.1 100 Continue\r\n\r\n"), Wait(body), Chunk(ok("done"))]
  })
  h.run(() => {
    let start = h.driver.now()
    assert_eq(fetch(h.client, expecting(b"payload")), "done")
    // The head went out alone, the body only after the 100: no waiting.
    assert_true(@utf8.decode(conn.writes[0]).has_suffix("\r\n\r\n"))
    assert_true(!@utf8.decode(conn.writes[0]).contains("payload"))
    assert_eq(body_written(conn), b"payload")
    assert_eq(h.driver.now(), start)
    assert_eq(h.client.idle_connections(), 1)
    h.finish()
  })
}

///|
test "a final answer before the 100 leaves the body unsent" {
  let h = Harness::new()
  let conn = recording(h, _ => [Chunk(ok("too large", status=413))])
  h.run(() => {
    let response = h.client.send(
      expecting(Bytes::make(1 << 20, b'x')),
      exchange(),
    )
    assert_eq(response.status, 413)
    assert_eq(body_of(response), b"too large")
    assert_eq(conn.writes.length(), 1)
    // The server may still be waiting for the body: not reused.
    assert_eq(h.client.idle_connections(), 0)
    h.finish()
  })
}

///|
test "without an answer the body follows after a second" {
  for chunked in [false, true] {
    let h = Harness::new()
    let conn = recording(h, body => [Wait(body), Chunk(ok("done"))])
    h.run(() => {
      let request = if chunked {
        @mttp_core.Request::post("http://example.test/")
        .body_stream(@sim.Feed::bytes(h.driver, [b"pay", b"load"]))
        .header("Expect", "100-continue")
      } else {
        expecting(b"payload")
      }
      let start = h.driver.now()
      assert_eq(fetch(h.client, request), "done")
      assert_eq(h.driver.now() - start, 1000L)
      let body = body_written(conn)
      assert_eq(
        body,
        if chunked {
          b"3\r\npay\r\n4\r\nload\r\n0\r\n\r\n"
        } else {
          b"payload"
        },
      )
      h.finish()
    })
  }
}

///|
test "the wait for the 100 ends at the attempt deadline" {
  let h = Harness::new()
  let never = h.coordination.signal()
  let conn = recording(h, _ => [Wait(never)])
  h.run(() => {
    let start = h.driver.now()
    let failed = failing(() => {
      ignore(h.client.send(expecting(b"payload"), exchange(timeout_ms=300)))
    })
    assert_eq(failed, (Timeout(ms=300), Write))
    assert_eq(h.driver.now() - start, 300L)
    assert_eq(conn.writes.length(), 1)
    h.finish()
  })
}

///|
test "a request without the expectation or a body does not wait" {
  for
    request in [
      @mttp_core.Request::post("http://example.test/").body_bytes(b"payload"),
      @mttp_core.Request::post("http://example.test/").header(
        "Expect", "100-continue",
      ),
    ] {
    let h = Harness::new()
    let conn = recording(h, _ => [Chunk(ok("done"))])
    h.run(() => {
      let start = h.driver.now()
      assert_eq(fetch(h.client, request), "done")
      assert_eq(h.driver.now(), start)
      // Head and body, if any, in one write.
      assert_eq(conn.writes.length(), 1)
      h.finish()
    })
  }
}

// Streamed responses while the server stops: a stream marked
// `close_on_shutdown` is cut and its response ended as its framing allows;
// any other stream is still written to its end.

///|
/// A response stream that gives `first`, then waits for `release` before
/// giving `last` and its end; counts its pulls and closes.
priv struct Live {
  release : &@rt.Signal
  mut pulls : Int32
  mut closes : Int32
  mut closed : Bool
}

///|
fn Live::new(h : Harness) -> Live {
  { release: h.coordination.signal(), pulls: 0, closes: 0, closed: false, }
}

///|
impl @mttp.BodyStream for Live with fn read_some(self) {
  if self.closed {
    return None
  }
  self.pulls += 1
  match self.pulls {
    1 => Some(b"first")
    2 => {
      self.release.wait()
      Some(b"last")
    }
    _ => None
  }
}

///|
impl @mttp.BodyStream for Live with fn close(self) {
  if !self.closed {
    self.closed = true
    self.closes += 1
  }
}

///|
/// A response with `body` that may be cut when the server stops.
fn cut_at_shutdown(body : @mttp.Body) -> @mttp.Response {
  let response = @mttp.Response::new(200, body~)
  {
    ..response,
    attributes: response.attributes.put(@mttp.close_on_shutdown, true),
  }
}

///|
/// Serves the server end of a new pair with `stopping` and returns a client
/// on the other end.
fn Harness::serve_stopping(
  self : Harness,
  handler : @mttp.Handler,
  stopping : Ref[Bool],
) -> (Client, @driver.Task) {
  let (client, server) = @sim.pair(self.coordination)
  self.closes.push(() => server.closes())
  let task = self.serve_on(server, handler, stopping=() => stopping.val)
  ({ conn: client, pending: b"", }, task)
}

///|
test "a close_on_shutdown stream is cut and ended with its last chunk when the server stops" {
  let h = Harness::new()
  let stopping = Ref(false)
  let live = Live::new(h)
  h.run(() => {
    let (client, task) = h.serve_stopping(
      _ => cut_at_shutdown(Stream(@mttp.StreamBody::new(live))),
      stopping,
    )
    client.send(get("/") + get("/never"))
    h.driver.sleep(10)
    assert_eq(live.pulls, 2)
    stopping.val = true
    let reply = client.expect()
    // The pull waiting for an event is cancelled within one poll.
    assert_true(h.driver.now() <= 260L)
    assert_eq(reply.status, 200)
    assert_eq(reply.headers.get("transfer-encoding"), Some("chunked"))
    assert_eq(reply.headers.get("connection"), None)
    assert_eq(reply.text(), "first")
    assert_eq(client.rest(), "")
    ignore(task.wait())
    client.conn.close()
  })
  assert_eq(live.pulls, 2)
  assert_eq(live.closes, 1)
  assert_eq(h.errors.length(), 0)
}

///|
test "a close_on_shutdown stream is not pulled once the server is stopping" {
  let h = Harness::new()
  let stopping = Ref(false)
  let live = Live::new(h)
  h.run(() => {
    let (client, task) = h.serve_stopping(
      _ => {
        stopping.val = true
        cut_at_shutdown(Stream(@mttp.StreamBody::new(live)))
      },
      stopping,
    )
    client.send(get("/"))
    let reply = client.expect()
    assert_eq(reply.status, 200)
    assert_eq(reply.headers.get("connection"), Some("close"))
    assert_eq(reply.text(), "")
    assert_eq(client.rest(), "")
    ignore(task.wait())
    client.conn.close()
  })
  assert_eq(live.pulls, 0)
  assert_eq(live.closes, 1)
  assert_eq(h.errors.length(), 0)
}

///|
test "a close_on_shutdown stream with a length is cut by closing the connection" {
  let h = Harness::new()
  let stopping = Ref(false)
  let live = Live::new(h)
  h.run(() => {
    let (client, task) = h.serve_stopping(
      _ => cut_at_shutdown(Stream(@mttp.StreamBody::new(live, length=100L))),
      stopping,
    )
    client.send(get("/"))
    h.driver.sleep(10)
    stopping.val = true
    // The client sees 5 of the 100 bytes and then the end of the
    // connection: an incomplete response, not a shorter one.
    let out = client.rest()
    assert_true(out.contains("content-length: 100\r\n"))
    assert_true(out.has_suffix("\r\n\r\nfirst"))
    ignore(task.wait())
    client.conn.close()
  })
  assert_eq(live.closes, 1)
  assert_eq(h.errors.length(), 0)
}

///|
test "a close_on_shutdown stream that fails is answered as any failing stream" {
  let h = Harness::new()
  let pieces = Pieces::new(
    [],
    failure=@mttp.TransportError(kind=Network, phase=Body, detail="gone"),
  )
  let out = h.exchange(get("/") |> @mttp.encode_utf8, _ => {
    cut_at_shutdown(Stream(@mttp.StreamBody::new(pieces)))
  })
  assert_true(out.has_prefix("HTTP/1.1 500 "))
  assert_eq(h.errors.map(kind_phase), [(Network, Body)])
  assert_eq(pieces.closes, 1)
}

///|
test "a stream without close_on_shutdown is still written to its end when the server stops" {
  let h = Harness::new()
  let stopping = Ref(false)
  let live = Live::new(h)
  h.run(() => {
    let (client, task) = h.serve_stopping(
      _ => @mttp.Response::new(200, body=Stream(@mttp.StreamBody::new(live))),
      stopping,
    )
    client.send(get("/") + get("/never"))
    h.driver.sleep(10)
    stopping.val = true
    h.driver.sleep(1000)
    assert_eq(live.pulls, 2)
    assert_eq(live.closes, 0)
    live.release.notify()
    let reply = client.expect()
    assert_eq(reply.text(), "firstlast")
    assert_eq(client.rest(), "")
    ignore(task.wait())
    client.conn.close()
  })
  assert_eq(live.pulls, 3)
  assert_eq(live.closes, 1)
  assert_eq(h.errors.length(), 0)
}

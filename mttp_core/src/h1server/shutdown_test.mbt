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
impl @mttp_core.BodyStream for Live with fn read_some(self) {
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
impl @mttp_core.BodyStream for Live with fn close(self) {
  if !self.closed {
    self.closed = true
    self.closes += 1
  }
}

///|
/// A response with `body` that may be cut when the server stops.
fn cut_at_shutdown(body : @mttp_core.Body) -> @mttp_core.Response {
  let response = @mttp_core.Response::new(200, body~)
  {
    ..response,
    attributes: response.attributes.put(@mttp_core.close_on_shutdown, true),
  }
}

///|
/// Serves the server end of a new pair with `stopping` and returns a client
/// on the other end.
fn Harness::serve_stopping(
  self : Harness,
  handler : @mttp_core.Handler,
  stopping : Ref[Bool],
  before_close? : async (Bool) -> Unit noraise,
) -> (Client, @driver.Task) {
  let (client, server) = @sim.pair(self.coordination)
  self.closes.push(() => server.closes())
  let task = self.serve_on(
    server,
    handler,
    stopping=() => stopping.val,
    before_close?,
  )
  ({ conn: client, pending: b"", }, task)
}

///|
test "a close_on_shutdown stream is cut and ended with its last chunk when the server stops" {
  @sim.explore(schedule => {
    let h = Harness::new(schedule~)
    let stopping = Ref(false)
    let live = Live::new(h)
    h.run(() => {
      let (client, task) = h.serve_stopping(
        _ => cut_at_shutdown(Stream(@mttp_core.StreamBody::new(live))),
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
  })
}

///|
test "a close_on_shutdown stream is not pulled once the server is stopping" {
  @sim.explore(schedule => {
    let h = Harness::new(schedule~)
    let stopping = Ref(false)
    let live = Live::new(h)
    h.run(() => {
      let (client, task) = h.serve_stopping(
        _ => {
          stopping.val = true
          cut_at_shutdown(Stream(@mttp_core.StreamBody::new(live)))
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
  })
}

///|
test "a close_on_shutdown stream with a length is cut by closing the connection" {
  let h = Harness::new()
  let stopping = Ref(false)
  let live = Live::new(h)
  h.run(() => {
    let (client, task) = h.serve_stopping(
      _ => {
        cut_at_shutdown(Stream(@mttp_core.StreamBody::new(live, length=100L)))
      },
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
  @sim.explore(schedule => {
    let h = Harness::new(schedule~)
    let pieces = Pieces::new(
      [],
      failure=@mttp_core.TransportError(kind=Network, phase=Body, detail="gone"),
    )
    let out = h.exchange(get("/") |> @mttp_core.encode_utf8, _ => {
      cut_at_shutdown(Stream(@mttp_core.StreamBody::new(pieces)))
    })
    assert_true(out.has_prefix("HTTP/1.1 500 "))
    assert_eq(h.errors.map(kind_phase), [(Network, Body)])
    assert_eq(pieces.closes, 1)
  })
}

///|
test "a stream without close_on_shutdown is still written to its end when the server stops" {
  @sim.explore(schedule => {
    let h = Harness::new(schedule~)
    let stopping = Ref(false)
    let live = Live::new(h)
    h.run(() => {
      let (client, task) = h.serve_stopping(
        _ => {
          @mttp_core.Response::new(
            200,
            body=Stream(@mttp_core.StreamBody::new(live)),
          )
        },
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
  })
}

///|
/// What `before_close` heard of the connection served by `handler` for
/// `request`, when the server stops `stop_after_ms` in (never when `None`).
fn heard_clean(
  handler : (Harness) -> @mttp_core.Handler,
  request : String,
  stop_after_ms? : Int32,
) -> (Array[Bool], String) raise {
  let h = Harness::new()
  let stopping = Ref(false)
  let heard = []
  let mut out = ""
  h.run(() => {
    let (client, task) = h.serve_stopping(handler(h), stopping, before_close=clean => {
      heard.push(clean)
    })
    client.send(request)
    if stop_after_ms is Some(ms) {
      h.driver.sleep(ms)
      stopping.val = true
    }
    out = client.rest()
    ignore(task.wait())
    client.conn.close()
  })
  (heard, out)
}

///|
test "before_close hears a body delimited by the close as whole once it ended" {
  let (heard, out) = heard_clean(
    _ => {
      _ => {
        @mttp_core.Response::new(
          200,
          body=Stream(
            @mttp_core.StreamBody::new(Pieces::new([b"all", b" of it"])),
          ),
        )
      }
    },
    "GET / HTTP/1.0\r\n\r\n",
  )
  assert_true(out.contains("connection: close\r\n"))
  assert_true(out.has_suffix("\r\n\r\nall of it"))
  assert_eq(heard, [true])
}

///|
test "before_close hears a body delimited by the close and cut at shutdown as cut" {
  let (heard, out) = heard_clean(
    h => {
      let live = Live::new(h)
      _ => cut_at_shutdown(Stream(@mttp_core.StreamBody::new(live)))
    },
    "GET / HTTP/1.0\r\n\r\n",
    stop_after_ms=10,
  )
  // Without close_notify after it, the client can tell this body was cut.
  assert_true(out.has_suffix("\r\n\r\nfirst"))
  assert_eq(heard, [false])
}

///|
test "before_close hears a body with a length cut at shutdown as cut" {
  let (heard, _) = heard_clean(
    h => {
      let live = Live::new(h)
      _ => {
        cut_at_shutdown(Stream(@mttp_core.StreamBody::new(live, length=100L)))
      }
    },
    get("/"),
    stop_after_ms=10,
  )
  assert_eq(heard, [false])
}

///|
test "before_close hears a chunked body cut at shutdown as whole: its last chunk went" {
  let (heard, out) = heard_clean(
    h => {
      let live = Live::new(h)
      _ => cut_at_shutdown(Stream(@mttp_core.StreamBody::new(live)))
    },
    get("/"),
    stop_after_ms=10,
  )
  assert_true(out.has_suffix("0\r\n\r\n"))
  assert_eq(heard, [true])
}

///|
test "before_close hears a refusal as whole" {
  let (heard, out) = heard_clean(
    _ => reply("never"),
    "GET / HTTP/1.1\r\nhost: a\r\nhost: b\r\n\r\n",
  )
  assert_true(out.has_prefix("HTTP/1.1 400 "))
  assert_eq(heard, [true])
}

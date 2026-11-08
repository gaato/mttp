///|
test "a head that is not complete within header_timeout_ms is answered with 408" {
  for (complete_at, status) in [(99, "200"), (100, "408")] {
    let h = Harness::new()
    h.run(() => {
      let (client, task) = h.serve(reply("ok"), limits={
        ..@h1server.ServerLimits::default(),
        header_timeout_ms: 100,
      })
      client.send("GET / HTTP/1.1\r\nHost:")
      h.driver.sleep(complete_at)
      client.send(" example.test\r\nConnection: close\r\n\r\n") catch {
        _ => ()
      }
      let out = client.rest()
      assert_true(out.has_prefix("HTTP/1.1 \{status} "), msg=out)
      ignore(task.wait())
      client.conn.close()
    })
    if status == "408" {
      assert_eq(h.errors.map(kind_phase), [(Timeout(ms=100), Head)])
    }
  }
}

///|
test "an idle connection closes silently after header_timeout_ms" {
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(reply("ok"), limits={
      ..@h1server.ServerLimits::default(),
      header_timeout_ms: 50,
    })
    client.send(get("/"))
    assert_eq(client.expect().status, 200)
    let started = h.driver.now()
    assert_eq(client.rest(), "")
    assert_eq(h.driver.now() - started, 50L)
    ignore(task.wait())
    client.conn.close()
  })
  assert_eq(h.errors.length(), 0)
}

///|
test "the body deadline covers the whole body and trickling does not renew it" {
  let h = Harness::new()
  let sent = Ref(0)
  h.run(() => {
    let (client, task) = h.serve(echo(), limits={
      ..@h1server.ServerLimits::default(),
      body_timeout_ms: 160,
    })
    client.send(
      "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 10\r\n\r\n",
    )
    let producer = h.driver.spawn(() => {
      for _ in 0..<10 {
        h.driver.sleep(40)
        client.conn.write(b"x") catch {
          _ => return
        }
        sent.val += 1
      }
    })
    let reply = client.expect()
    assert_eq(reply.status, 408)
    assert_eq(reply.headers.get("connection"), Some("close"))
    producer.cancel()
    ignore(producer.wait() catch { _ => false })
    ignore(task.wait())
    client.conn.close()
  })
  assert_true(sent.val < 10)
  assert_eq(h.errors.map(kind_phase), [(Timeout(ms=160), Body)])
}

///|
test "a handler past handler_timeout_ms is cancelled and answered with 504" {
  let h = Harness::new()
  let cleaned = Ref(false)
  h.run(() => {
    let (client, task) = h.serve(
      _ => {
        defer {
          cleaned.val = true
        }
        h.driver.sleep(10000)
        @http.Response::new(200)
      },
      limits={
        ..@h1server.ServerLimits::default(),
        handler_timeout_ms: Some(5),
      },
    )
    client.send(get("/"))
    let out = client.rest()
    assert_true(out.has_prefix("HTTP/1.1 504 "))
    assert_eq(h.driver.now(), 5L)
    ignore(task.wait())
    client.conn.close()
  })
  assert_true(cleaned.val)
  assert_eq(h.errors.map(kind_phase), [(Timeout(ms=5), Unknown)])
}

///|
test "a handler that finishes within its budget keeps its response" {
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(
      _ => {
        h.driver.sleep(4)
        @http.Response::new(204)
      },
      limits={
        ..@h1server.ServerLimits::default(),
        handler_timeout_ms: Some(5),
      },
    )
    client.send(get("/", fields="Connection: close\r\n"))
    assert_eq(client.expect().status, 204)
    ignore(task.wait())
    client.conn.close()
    assert_eq(h.driver.now(), 4L)
  })
  assert_eq(h.errors.length(), 0)
}

///|
test "consumer pauses count against an unfinished body but not a completed EOF" {
  for complete in [false, true] {
    let h = Harness::new()
    let seen = []
    let pieces : Array[Bytes?] = []
    let out = h.exchange(
      @http.encode_utf8(post("/", if complete { "x" } else { "xy" })),
      request => {
        guard request.body is Stream(stream) else {
          return @http.Response::new(500)
        }
        let reader = stream.take() catch {
          _ => return @http.Response::new(500)
        }
        pieces.push(reader.read_some() catch { _ => None })
        h.driver.sleep(10)
        let next = reader.read_some() catch {
          error => {
            seen.push(kind_phase(error))
            None
          }
        }
        pieces.push(next)
        @http.Response::new(204)
      },
      limits={ ..@h1server.ServerLimits::default(), body_timeout_ms: 5, },
      chunk_bytes=1,
    )
    assert_true(
      out.has_prefix(if complete { "HTTP/1.1 204 " } else { "HTTP/1.1 408 " }),
    )
    assert_eq(seen, if complete { [] } else { [(Timeout(ms=5), Body)] })
    assert_eq(pieces, [Some(b"x"), None])
  }
}

///|
test "an unread body drain has a deadline and reports its failure" {
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(reply("accepted"), limits={
      ..@h1server.ServerLimits::default(),
      body_timeout_ms: 12,
    })
    client.send(
      "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 1\r\n\r\n",
    )
    assert_eq(client.expect().text(), "accepted")
    assert_eq(client.rest(), "")
    ignore(task.wait())
    assert_eq(h.driver.now(), 12L)
    client.conn.close()
  })
  assert_eq(h.errors.map(kind_phase), [(Timeout(ms=12), Body)])
}

///|
test "a peer that stops reading is cut off by the write deadline" {
  let h = Harness::new()
  let conn = Stalled::{
    reads: @sim.ScriptedConn::new([Chunk(@http.encode_utf8(get("/")))]),
    stuck: h.coordination.signal(),
    writes: 0,
    closed: false,
  }
  h.run(() => {
    @h1server.serve_conn(
      conn,
      reply("ok"),
      clock=h.clock,
      timer=h.timer,
      coordination=h.coordination,
      scheme="http",
      limits={ ..@h1server.ServerLimits::default(), body_timeout_ms: 25, },
      on_error=error => h.errors.push(error),
    )
    assert_eq(h.driver.now(), 25L)
  })
  assert_true(conn.closed)
  assert_eq(conn.writes, 1)
  assert_eq(h.errors.map(kind_phase), [(Timeout(ms=25), Write)])
}

///|
test "an independent first response producer timeout is 500 with an unread request body" {
  for sent_body in ["", "abc"] {
    let h = Harness::new()
    let closes = Ref(0)
    h.run(() => {
      let (client, task) = h.serve(
        _ => {
          @http.Response::new(
            200,
            body=Stream(
              @http.StreamBody::new(Stall::{
                driver: h.driver,
                closes,
                step: 1,
                closed: false,
              }),
            ),
          )
        },
        limits={ ..@h1server.ServerLimits::default(), body_timeout_ms: 30, },
      )
      client.send(
        "POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\n" + sent_body,
      )
      let out = client.rest()
      assert_true(out.has_prefix("HTTP/1.1 500 "), msg=out)
      ignore(task.wait())
      assert_eq(h.driver.now(), 30L)
      client.conn.close()
    })
    assert_eq(closes.val, 1)
    assert_eq(h.errors.map(kind_phase), [(Timeout(ms=30), Body)])
  }
}

///|
test "a response timeout after a successful partial input pull is a producer failure" {
  let h = Harness::new()
  let closes = Ref(0)
  h.run(() => {
    let (client, task) = h.serve(
      request => {
        guard request.body is Stream(stream) else {
          return @http.Response::new(500)
        }
        let reader = stream.take() catch {
          _ => return @http.Response::new(500)
        }
        @http.Response::new(
          200,
          body=Stream(
            @http.StreamBody::new(InputThenStall::{
              driver: h.driver,
              reader,
              closes,
              closed: false,
            }),
          ),
        )
      },
      limits={ ..@h1server.ServerLimits::default(), body_timeout_ms: 30, },
    )
    client.send("POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\na")
    assert_eq(client.expect().status, 500)
    assert_eq(client.rest(), "")
    ignore(task.wait())
    client.conn.close()
  })
  assert_eq(closes.val, 1)
  assert_eq(h.errors.map(kind_phase), [(Timeout(ms=30), Body)])
}

///|
priv struct InputThenStall {
  driver : @driver.Driver
  reader : &@http.BodyStream
  closes : Ref[Int32]
  mut closed : Bool
}

///|
impl @http.BodyStream for InputThenStall with fn read_some(self) {
  ignore(self.reader.read_some())
  self.driver.sleep(100000)
  None
}

///|
impl @http.BodyStream for InputThenStall with fn close(self) {
  if !self.closed {
    self.closed = true
    self.reader.close()
    self.closes.val += 1
  }
}

///|
test "a response producer that stalls is cut off after body_timeout_ms" {
  let h = Harness::new()
  let closes = Ref(0)
  h.run(() => {
    let (client, task) = h.serve(
      _ => {
        @http.Response::new(
          200,
          body=Stream(
            @http.StreamBody::new(Stall::{
              driver: h.driver,
              closes,
              step: 0,
              closed: false,
            }),
          ),
        )
      },
      limits={ ..@h1server.ServerLimits::default(), body_timeout_ms: 30, },
    )
    client.send(get("/"))
    let out = client.rest()
    // The first piece arrived; the stalled second one ends the connection.
    assert_true(out.has_prefix("HTTP/1.1 200 "))
    assert_true(out.has_suffix("5\r\nfirst\r\n"))
    ignore(task.wait())
    client.conn.close()
  })
  assert_eq(closes.val, 1)
  assert_eq(h.errors.map(kind_phase), [(Timeout(ms=30), Body)])
}

///|
/// A response stream that yields one piece, then waits far too long.
priv struct Stall {
  driver : @driver.Driver
  closes : Ref[Int32]
  mut step : Int32
  mut closed : Bool
}

///|
impl @http.BodyStream for Stall with fn read_some(self) {
  self.step += 1
  if self.step == 1 {
    return Some(b"first")
  }
  self.driver.sleep(100000)
  None
}

///|
impl @http.BodyStream for Stall with fn close(self) {
  if !self.closed {
    self.closed = true
    self.closes.val += 1
  }
}

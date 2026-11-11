///|
test "100 Continue is sent only when the handler reads the body" {
  let handler : @mttp.Handler = request => {
    if request.headers.get("authorization") is None {
      return @mttp.Response::new(401)
    }
    echo()(request)
  }
  // A handler that refuses without reading never invites the body, and the
  // connection closes since the client may send it anyway.
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(handler)
    client.send(
      "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n",
    )
    let out = client.rest()
    assert_true(out.has_prefix("HTTP/1.1 401 "))
    assert_false(out.contains("100 Continue"))
    assert_true(out.contains("connection: close\r\n"))
    ignore(task.wait())
    client.conn.close()
  })
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(handler)
    client.send(
      "POST / HTTP/1.1\r\nHost: example.test\r\nAuthorization: yes\r\nContent-Length: 3\r\nExpect: 100-Continue\r\n\r\n",
    )
    assert_eq(client.expect().status, 100)
    client.send("abc")
    let reply = client.expect()
    assert_eq(reply.status, 200)
    assert_eq(reply.text(), "abc")
    assert_eq(reply.headers.get("connection"), None)
    // Once the body was read, the connection carries the next request.
    client.send(get("/next", fields="Authorization: yes\r\n"))
    assert_eq(client.expect().status, 200)
    client.conn.close()
    ignore(task.wait())
  })
}

///|
test "a full read ahead buffer is consumed before further body reads and preserves reuse" {
  for chunk_bytes in [17, 65536] {
    let h = Harness::new()
    let upload = String::make(70000, 'x')
    let calls = Ref(0)
    let out = h.exchange(
      @mttp.encode_utf8(post("/", upload) + get("/next")),
      request => {
        calls.val += 1
        h.driver.sleep(10)
        echo()(request)
      },
      chunk_bytes~,
    )
    assert_true(out.contains("\r\n\r\n" + upload + "HTTP/1.1 200 "))
    assert_eq(calls.val, 2)
    assert_eq(h.errors.length(), 0)
  }
}

///|
test "an HTTP/1.0 expectation of 100-continue is ignored" {
  let h = Harness::new()
  let out = h.exchange(
    b"POST / HTTP/1.0\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\nabc",
    echo(),
  )
  assert_false(out.contains("100 Continue"))
  assert_true(out.has_suffix("\r\n\r\nabc"))
}

///|
test "no 100 Continue is owed for a request without a body" {
  let h = Harness::new()
  h.run(() => {
    let (client, task) = h.serve(_ => @mttp.Response::new(204))
    client.send(get("/", fields="Expect: 100-continue\r\n"))
    let reply = client.expect()
    assert_eq(reply.status, 204)
    assert_eq(reply.headers.get("connection"), None)
    client.send(get("/again"))
    assert_eq(client.expect().status, 204)
    client.conn.close()
    ignore(task.wait())
  })
}

///|
test "chunked request bodies drop their trailers and keep pipelining" {
  let h = Harness::new()
  let trailers = []
  let out = h.exchange(
    b"POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n2;ext=1\r\nbc\r\n0\r\nX-Trailer: yes\r\n\r\nGET /next HTTP/1.1\r\nHost: example.test\r\n\r\n",
    request => {
      trailers.push(request.headers.get("x-trailer"))
      echo()(request)
    },
    chunk_bytes=3,
  )
  assert_eq(out.split("HTTP/1.1 200").count(), 3)
  assert_true(out.contains("\r\n\r\nabcHTTP/1.1"))
  assert_eq(trailers, [None, None])
}

///|
test "an echoed request body keeps its failure status" {
  for
    (chunk, status) in [
      ("4\r\nabcd\r\n0\r\n\r\n", "413"),
      ("wrong\r\n", "400"),
      ("", "408"),
    ] {
    let h = Harness::new()
    h.run(() => {
      let (client, task) = h.serve(
        request => @mttp.Response::new(200, body=request.body),
        limits={
          ..@h1server.ServerLimits::default(),
          max_body_bytes: 3,
          body_timeout_ms: 30,
        },
      )
      client.send(
        "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n" +
        chunk,
      )
      let out = client.rest()
      assert_true(out.has_prefix("HTTP/1.1 \{status} "), msg=out)
      ignore(task.wait())
      client.conn.close()
    })
  }
}

///|
test "a body the peer ends early is reported in phase Body" {
  let h = Harness::new()
  let out = h.exchange(
    @mttp.encode_utf8(
      "POST / HTTP/1.1\r\nHost: example.test\r\nContent-Length: 10\r\n\r\nabc",
    ),
    echo(),
  )
  assert_true(out.has_prefix("HTTP/1.1 400 "))
  assert_eq(h.errors.map(kind_phase), [(Protocol, Body)])
}

///|
test "the request body is closed when the exchange ends" {
  let h = Harness::new()
  let bodies : Array[@mttp.StreamBody] = []
  let out = h.exchange(@mttp.encode_utf8(post("/", "abc") + get("/next")), request => {
    if request.body is Stream(stream) {
      bodies.push(stream)
    }
    @mttp.Response::new(204)
  })
  assert_eq(out.split("HTTP/1.1 204").count(), 3)
  assert_eq(bodies.length(), 1)
  // A body that was never taken cannot be taken after its exchange.
  try bodies[0].take() catch {
    error => assert_true(error is @mttp.TransportError(kind=Unreplayable, ..))
  } noraise {
    _ => fail("the body outlived its exchange")
  }
}

///|
test "a body declared by Content-Length reports its length" {
  let h = Harness::new()
  let lengths = []
  ignore(
    h.exchange(@mttp.encode_utf8(post("/", "hello") + get("/")), request => {
      lengths.push(request.body.length())
      @mttp.Response::new(204)
    }),
  )
  assert_eq(lengths, [Some(5L), Some(0L)])
}

///|
test "a response producer cannot hide a request failure or reuse its connection" {
  for connection_close in [false, true] {
    for prefix in [false, true] {
      let h = Harness::new()
      let calls = Ref(0)
      let close = if connection_close { "Connection: close\r\n" } else { "" }
      let out = h.exchange(
        @mttp.encode_utf8(
          "POST / HTTP/1.1\r\nHost: h\r\n\{close}Transfer-Encoding: chunked\r\n\r\nbad-chunk\r\n" +
          get("/never"),
        ),
        request => {
          calls.val += 1
          guard request.body is Stream(stream) else {
            return @mttp.Response::new(500)
          }
          let reader = stream.take() catch {
            _ => return @mttp.Response::new(500)
          }
          @mttp.Response::new(
            200,
            body=Stream(
              @mttp.StreamBody::new(Recovering::{ reader, prefix, step: 0, }),
            ),
          )
        },
      )
      assert_true(
        out.has_prefix(if prefix { "HTTP/1.1 200 " } else { "HTTP/1.1 400 " }),
        msg=out,
      )
      assert_eq(out.split("HTTP/1.1 ").count(), 2)
      assert_eq(calls.val, 1)
      assert_eq(h.errors.map(kind_phase), [(Protocol, Body)])
    }
  }
}

///|
/// An application stream that catches a request read failure and continues.
priv struct Recovering {
  reader : &@mttp.BodyStream
  prefix : Bool
  mut step : Int32
}

///|
impl @mttp.BodyStream for Recovering with fn read_some(self) {
  self.step += 1
  if self.prefix && self.step == 1 {
    return Some(b"prefix")
  }
  if self.step == (if self.prefix { 2 } else { 1 }) {
    ignore(self.reader.read_some() catch { _ => None })
    return Some(b"recovered")
  }
  None
}

///|
impl @mttp.BodyStream for Recovering with fn close(self) {
  self.reader.close()
}

///|
test "closing an acquired request source still lets the engine drain it" {
  let h = Harness::new()
  let errors = []
  let out = h.exchange(@mttp.encode_utf8(post("/", "abc") + get("/next")), request => {
    if request.body is Stream(stream) {
      let reader = stream.take() catch { _ => return @mttp.Response::new(500) }
      stream.close()
      ignore(
        reader.read_some() catch {
          error => {
            errors.push(kind_phase(error))
            None
          }
        },
      )
    }
    @mttp.Response::new(204)
  })
  assert_eq(out.split("HTTP/1.1 204").count(), 3)
  // The acquired reader detects a premature end of its declared length.
  assert_eq(errors, [(Protocol, Body)])
}

///|
async test "gaato/mttp_core's Backend contract" {
  // Port 1 refuses connections, so a send that broke a rule would fail
  // there rather than reach a server.
  @sim.check_backend_contract(
    () => @h2client.H2Backend::new(h2c=true),
    url="http://127.0.0.1:1/",
  )
}

///|
async test "a nonpositive timeout fails at once with Timeout in Pool" {
  let b = @h2client.H2Backend::new(h2c=true)
  defer b.close()
  let error = failure(b, @mttp_core.Request::get("http://127.0.0.1:1/"), options={
    ..defaults,
    timeout_ms: Some(0),
  })
  guard error is @mttp_core.TransportError(kind=Timeout(ms=0), phase=Pool, ..) else {
    fail("unexpected \{error.to_repr()}")
  }
}

///|
/// A request body of the given pieces that counts its closes.
priv struct Source {
  pieces : Array[Bytes]
  mut next : Int32
  mut closed : Int32
}

///|
impl @mttp_core.BodyStream for Source with fn read_some(self) {
  if self.next >= self.pieces.length() {
    return None
  }
  self.next += 1
  Some(self.pieces[self.next - 1])
}

///|
impl @mttp_core.BodyStream for Source with fn close(self) {
  self.closed += 1
}

///|
async test "a stream body shorter than its declared length sends nothing" {
  let b = @h2client.H2Backend::new(h2c=true)
  defer b.close()
  let source = { pieces: [], next: 0, closed: 0, }
  let error = failure(
    b,
    @mttp_core.Request::post("http://127.0.0.1:1/").body_stream(
      source,
      length=5L,
    ),
  )
  // Port 1 would have refused the connection with Connect.
  guard error is @mttp_core.TransportError(kind=Protocol, ..) else {
    fail("unexpected \{error.to_repr()}")
  }
  assert_eq(source.closed, 1)
}

///|
async test "an empty stream body is sent as an empty body" {
  with_server(server => {
    let b = backend(h2c=true)
    defer b.close()
    let source = { pieces: [], next: 0, closed: 0, }
    let response = b.send(
      @mttp_core.Request::post(server.h2c + "/echo").body_stream(source),
      defaults,
    )
    assert_eq(response.headers.get("x-received"), Some("0"))
    assert_eq(text(response), "")
    assert_eq(source.closed, 1)
  })
}

///|
async test "closing the backend fails the exchanges in flight with Closed" {
  with_server(server => {
    let b = backend()
    let outcome : Ref[@mttp_core.TransportError?] = Ref(None)
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        outcome.val = Some(
          failure(b, @mttp_core.Request::get(server.tls + "/hang")),
        )
      })
      @async.sleep(300)
      b.close()
    })
    guard outcome.val is Some(@mttp_core.TransportError(kind=Closed, ..)) else {
      fail("the in-flight send did not fail with Closed")
    }
  })
}

///|
async test "a body read after its end reads nothing" {
  with_server(server => {
    let b = backend()
    defer b.close()
    let response = b.send(
      @mttp_core.Request::get(server.tls + "/hello"),
      defaults,
    )
    guard response.body is Stream(stream) else { fail("not a stream") }
    let reader = stream.take()
    assert_eq(reader.read_some(), Some(b"hello"))
    assert_eq(reader.read_some(), None)
    assert_eq(reader.read_some(), None)
  })
}

///|
/// Closing a body resets its stream with CANCEL and leaves the connection to
/// the next request. (Not under a one-stream limit: node:http2 counts a
/// stream the client reset until its own stream object is destroyed, and
/// answers a stream opened meanwhile with ENHANCE_YOUR_CALM.)
async test "a body closed before its end leaves the connection to the next" {
  with_server(server => {
    let b = backend()
    defer b.close()
    for _ in 0..<5 {
      let response = b.send(
        @mttp_core.Request::get(server.tls + "/big/1000000"),
        defaults,
      )
      response.close()
    }
    let response = b.send(
      @mttp_core.Request::get(server.tls + "/session"),
      defaults,
    )
    assert_eq(text(response), "1")
    assert_eq(b.connections(), 1)
  })
}

///|
async test "gaato/mttp's Client over the backend, under Decompress" {
  with_server(server => {
    let client = @mttp.client(
      base_url=server.tls,
      backend=@codings.Decompress::new(backend()),
    )
    defer client.close()
    let redirected = client.send(@mttp.get("/redirect"))
    assert_eq(redirected.status, 200)
    assert_eq(redirected.body, Ok("hello"))
    let decoded = client.send(@mttp.get("/gzip"))
    assert_eq(decoded.body, Ok("hello gzip"))
  })
}

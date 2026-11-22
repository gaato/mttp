// One deadline bounds the whole attempt, the request body's reads included,
// and a close that comes while the send waits is seen.

///|
/// A request body whose read number `stall_at` (from 1) never returns on its
/// own; the others give a small piece.
priv struct Stalling {
  stall_at : Int32
  mut reads : Int32
  mut closed : Int32
}

///|
impl @mttp_core.BodyStream for Stalling with fn read_some(self) {
  self.reads += 1
  if self.reads == self.stall_at {
    @async.sleep(600000)
  }
  Some(b"piece")
}

///|
impl @mttp_core.BodyStream for Stalling with fn close(self) {
  self.closed += 1
}

///|
async test "a stalled first body read times out in Pool, unsent" {
  with_server(server => {
    let backend = tls_backend()
    defer backend.close()
    let source = Stalling::{ stall_at: 1, reads: 0, closed: 0, }
    let e = send_error(
      backend,
      @mttp_core.Request::post(server.tls + "/echo").body_stream(source),
      options={ ..@mttp_core.SendOptions::default(), timeout_ms: Some(300), },
    )
    guard e is @mttp_core.TransportError(kind=Timeout(ms=300), phase=Pool, ..) else {
      fail("unexpected \{e.to_repr()}")
    }
    assert_true(e.is_unsent())
    assert_eq(source.closed, 1)
  })
}

///|
async test "a stalled later body read times out in Write" {
  with_server(server => {
    let backend = tls_backend()
    defer backend.close()
    let source = Stalling::{ stall_at: 2, reads: 0, closed: 0, }
    let e = send_error(
      backend,
      @mttp_core.Request::post(server.tls + "/echo").body_stream(source),
      options={ ..@mttp_core.SendOptions::default(), timeout_ms: Some(500), },
    )
    guard e is @mttp_core.TransportError(kind=Timeout(ms=500), phase=Write, ..) else {
      fail("unexpected \{e.to_repr()}")
    }
    assert_eq(source.closed, 1)
  })
}

///|
async test "a close while the first body read waits ends the send with Closed" {
  let backend = CurlBackend::new(proxy=@h1client.ProxyConfig::none())
  // A first read that waits until the close, then returns.
  let gate = @async.Mutex()
  gate.acquire()
  let slow = SlowFirst::{ gate, closed: 0, }
  let outcome : Ref[@mttp_core.TransportError?] = Ref(None)
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      outcome.val = Some(
        send_error(
          backend,
          @mttp_core.Request::post("http://127.0.0.1:1/").body_stream(slow),
        ),
      )
    })
    @async.sleep(100)
    backend.close()
    gate.release()
  })
  guard outcome.val
    is Some(@mttp_core.TransportError(kind=Closed, phase=Pool, ..)) else {
    fail("the send did not end with Closed in Pool")
  }
  assert_eq(slow.closed, 1)
}

///|
/// A request body whose first read waits for `gate`.
priv struct SlowFirst {
  gate : @async.Mutex
  mut closed : Int32
}

///|
impl @mttp_core.BodyStream for SlowFirst with fn read_some(self) {
  self.gate.acquire()
  self.gate.release()
  Some(b"late")
}

///|
impl @mttp_core.BodyStream for SlowFirst with fn close(self) {
  self.closed += 1
}

///|
async test "engines made and closed in a row, idle or with an exchange" {
  for _ in 0..<2000 {
    CurlBackend::new(proxy=@h1client.ProxyConfig::none()).close()
  }
  for _ in 0..<200 {
    let backend = CurlBackend::new(proxy=@h1client.ProxyConfig::none())
    send_error(backend, @mttp_core.Request::get("http://127.0.0.1:1/"))
    |> ignore
    backend.close()
  }
  // Dropped without close: the boxes' finalizers close them.
  for _ in 0..<200 {
    CurlBackend::new(proxy=@h1client.ProxyConfig::none()) |> ignore
  }
}

///|
async test "an early answer ends a send whose upload read is stalled, with or without a deadline" {
  with_server(server => {
    for timeout_ms in [None, Some(5000)] {
      let backend = tls_backend()
      defer backend.close()
      // The second read never returns on its own; the server answers 413
      // without reading the body.
      let source = Stalling::{ stall_at: 2, reads: 0, closed: 0, }
      let response = backend.send(
        @mttp_core.Request::post(server.tls + "/early/413").body_stream(source),
        { ..@mttp_core.SendOptions::default(), timeout_ms, },
      )
      assert_eq(response.status, 413)
      assert_eq(text(response), "early")
      assert_eq(source.closed, 1)
    }
  })
}

///|
async test "a close while an upload read is stalled ends the send with Closed" {
  with_server(server => {
    let backend = tls_backend()
    let source = Stalling::{ stall_at: 2, reads: 0, closed: 0, }
    let outcome : Ref[@mttp_core.TransportError?] = Ref(None)
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        outcome.val = Some(
          send_error(
            backend,
            @mttp_core.Request::post(server.tls + "/echo").body_stream(source),
          ),
        )
      })
      @async.sleep(500)
      backend.close()
    })
    guard outcome.val is Some(@mttp_core.TransportError(kind=Closed, ..)) else {
      fail("the stalled send did not end with Closed")
    }
    assert_eq(source.closed, 1)
  })
}

///|
async test "an Exchange deadline holds for a body already buffered" {
  with_server(server => {
    let backend = tls_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.tls + "/hello"),
      { timeout_ms: Some(300), body: Exchange(max_bytes=100), },
    )
    // The whole body has arrived by now; reading it after the deadline must
    // still end the exchange.
    @async.sleep(500)
    let e = body_error(response)
    guard e is @mttp_core.TransportError(kind=Timeout(ms=300), phase=Body, ..) else {
      fail("unexpected \{e}")
    }
  })
}

///|
async test "an early success answer during a stalled upload, over HTTP/2 and HTTP/1.1" {
  with_server(server => {
    let h1 = CurlBackend::with_version(
      2,
      http3=false,
      trust=PemFile(testdata("root.pem")),
    )
    let h2 = tls_backend()
    defer {
      h1.close()
      h2.close()
    }
    for backend in [h2, h1] {
      let source = Stalling::{ stall_at: 2, reads: 0, closed: 0, }
      let response = backend.send(
        @mttp_core.Request::post(server.tls + "/early/200").body_stream(source),
        { timeout_ms: Some(5000), body: Exchange(max_bytes=100), },
      )
      assert_eq(response.status, 200)
      assert_eq(text(response), "early")
      assert_eq(source.closed, 1)
    }
  })
}

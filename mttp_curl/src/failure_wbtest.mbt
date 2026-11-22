///|
/// The error a send raises, or a test failure if it returns.
async fn send_error(
  backend : CurlBackend,
  request : @mttp_core.Request,
  options~ : @mttp_core.SendOptions = @mttp_core.SendOptions::default(),
) -> @mttp_core.TransportError {
  let response = backend.send(request, options) catch { e => return e }
  (response.body.read_all(max=1 << 20) |> ignore) catch {
    e => return e
  }
  fail("the send succeeded with \{response.status}")
}

///|
/// The error reading `response`'s body raises, or a test failure.
async fn body_error(
  response : @mttp_core.Response,
) -> @mttp_core.TransportError {
  (response.body.read_all(max=1 << 20) |> ignore) catch {
    e => return e
  }
  fail("the body was read whole")
}

///|
async test "a refused port fails in Dial, unsent" {
  let backend = h2c_backend()
  defer backend.close()
  let e = send_error(backend, @mttp_core.Request::post("http://127.0.0.1:1/x"))
  guard e is @mttp_core.TransportError(kind=Connect, phase=Dial, ..) else {
    fail("unexpected \{e.to_repr()}")
  }
  assert_true(e.is_unsent())
}

///|
async test "an untrusted certificate fails in Dial, unsent" {
  with_server(server => {
    let backend = CurlBackend::new(proxy=@h1client.ProxyConfig::none())
    defer backend.close()
    let e = send_error(backend, @mttp_core.Request::get(server.tls + "/hello"))
    guard e is @mttp_core.TransportError(kind=Connect, phase=Dial, ..) else {
      fail("unexpected \{e.to_repr()}")
    }
    assert_true(e.is_unsent())
  })
}

///|
async test "a stream refused every time ends in Network after libcurl's own attempts" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    // libcurl sends a refused stream again by itself, up to five times, a
    // POST too (HTTP/2 says it was not processed). When all are refused it
    // gives up with an error that a dead connection also ends in, so the
    // backend cannot say unsent: Network.
    for
      request in [
        @mttp_core.Request::get(server.h2c + "/refuse"),
        @mttp_core.Request::post(server.h2c + "/refuse"),
      ] {
      let e = send_error(backend, request)
      guard e is @mttp_core.TransportError(kind=Network, ..) else {
        fail("unexpected \{e}")
      }
      assert_false(e.is_unsent())
    }
  })
}

///|
async test "a stream above GOAWAY is sent again by libcurl, a POST included" {
  // HTTP/2 says such a stream was not processed, so even a request that is
  // not idempotent may go again. The server sends GOAWAY on its first
  // connection only, so each method gets a server of its own.
  for meth in [@mttp_core.Method::Get, Post] {
    with_server(server => {
      let backend = tls_backend()
      defer backend.close()
      // A first stream, so that the GOAWAY can name it.
      backend.send(
        @mttp_core.Request::get(server.tls + "/hello"),
        @mttp_core.SendOptions::default(),
      ).body.read_all(max=100)
      |> ignore
      let response = backend.send(
        @mttp_core.Request::new(meth, server.tls + "/goaway"),
        @mttp_core.SendOptions::default(),
      ) catch {
        // libcurl 7.88 does not send it again and reports a framing error:
        // not unsent, so mttp's Client resends only an idempotent request.
        e => {
          guard curl_version_num() < 0x080e00 &&
            e is @mttp_core.TransportError(kind=Protocol, ..) &&
            !e.is_unsent() else {
            fail("unexpected \{e}")
          }
          return
        }
      }
      assert_eq(text(response), "after goaway")
    })
  }
}

///|
async test "a reused connection that dies before an answer: GET is sent again, POST once" {
  with_server(server => {
    let backend = CurlBackend::with_version(
      2,
      http3=false,
      trust=PemFile(testdata("root.pem")),
    )
    defer backend.close()
    let drops = async fn() -> String {
      text(
        backend.send(
          @mttp_core.Request::get(server.tls + "/drops"),
          @mttp_core.SendOptions::default(),
        ),
      )
    }
    // Each connection answers its first /drop and closes on the next one.
    let kept = backend.send(
      @mttp_core.Request::post(server.tls + "/drop"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(text(kept), "kept")
    let e = send_error(backend, @mttp_core.Request::post(server.tls + "/drop"))
    guard e is @mttp_core.TransportError(kind=Network, ..) else {
      fail("unexpected \{e}")
    }
    assert_false(e.is_unsent())
    // The POST reached the server once: libcurl did not send it again.
    assert_eq(drops(), "1")
    // A GET on a reused connection that dies: libcurl sends it again on a
    // new connection, where it is that connection's first and answered.
    let again = backend.send(
      @mttp_core.Request::get(server.tls + "/drop"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(text(again), "kept")
  })
}

///|
async test "a reset after the head fails in Body" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.h2c + "/reset-body"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(response.status, 200)
    let e = body_error(response)
    guard e is @mttp_core.TransportError(phase=Body, ..) else {
      fail("unexpected \{e.to_repr()}")
    }
  })
}

///|
async test "a deadline before the head is a Timeout after the request was sent" {
  with_server(server => {
    let backend = tls_backend()
    defer backend.close()
    let e = send_error(backend, @mttp_core.Request::get(server.tls + "/hang"), options={
      ..@mttp_core.SendOptions::default(),
      timeout_ms: Some(300),
    })
    // Before libcurl 8.10 the backend cannot tell the whole request was
    // sent, and says Write: sent all the same.
    let sent : @mttp_core.Phase = if knows_when_sent() { Head } else { Write }
    guard e is @mttp_core.TransportError(kind=Timeout(..), phase~, ..) &&
      phase == sent else {
      fail("unexpected \{e.to_repr()}")
    }
    assert_false(e.is_unsent())
    // The backend still works after the abandoned exchange.
    let response = backend.send(
      @mttp_core.Request::get(server.tls + "/hello"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(text(response), "hello")
  })
}

///|
async test "a stalled body times out per read when streaming" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.h2c + "/stall"),
      { timeout_ms: Some(5000), body: Stream(idle_ms=Some(300)), },
    )
    let e = body_error(response)
    guard e is @mttp_core.TransportError(kind=Timeout(..), phase=Body, ..) else {
      fail("unexpected \{e.to_repr()}")
    }
  })
}

///|
async test "a body past max_bytes is TooLarge in Body" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.h2c + "/big/100000"),
      { timeout_ms: None, body: Exchange(max_bytes=1000), },
    )
    let e = body_error(response)
    guard e
      is @mttp_core.TransportError(kind=TooLarge(limit=1000), phase=Body, ..) else {
      fail("unexpected \{e.to_repr()}")
    }
  })
}

///|
async test "a head past the bound is TooLarge in Head" {
  with_server(server => {
    let backend = { ..h2c_backend(), head_max: 1000, }
    defer backend.close()
    let e = send_error(
      backend,
      @mttp_core.Request::get(server.h2c + "/big-head/5000"),
    )
    guard e
      is @mttp_core.TransportError(kind=TooLarge(limit=1000), phase=Head, ..) else {
      fail("unexpected \{e.to_repr()}")
    }
  })
}

///|
async test "sends after close fail with Closed in Pool" {
  let backend = h2c_backend()
  backend.close()
  backend.close()
  let e = send_error(backend, @mttp_core.Request::get("http://127.0.0.1:1/"))
  guard e is @mttp_core.TransportError(kind=Closed, phase=Pool, ..) else {
    fail("unexpected \{e.to_repr()}")
  }
}

///|
async test "CONNECT and upgrades are refused before any I/O" {
  let backend = h2c_backend()
  defer backend.close()
  let connect = send_error(
    backend,
    @mttp_core.Request::new(Connect, "http://127.0.0.1:1/"),
  )
  guard connect is @mttp_core.TransportError(kind=Invalid, phase=Pool, ..) else {
    fail("unexpected \{connect.to_repr()}")
  }
  let upgrade = send_error(
    backend,
    @mttp_core.Request::get("http://127.0.0.1:1/").header(
      "upgrade", "websocket",
    ),
  )
  guard upgrade is @mttp_core.TransportError(kind=Invalid, phase=Pool, ..) else {
    fail("unexpected \{upgrade.to_repr()}")
  }
}

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
async test "REFUSED_STREAM, after libcurl's own attempts, is Refused and unsent" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let e = send_error(
      backend,
      @mttp_core.Request::post(server.h2c + "/refuse"),
    )
    guard e is @mttp_core.TransportError(kind=Refused, ..) else {
      fail("unexpected \{e.to_repr()}")
    }
    assert_true(e.is_unsent())
  })
}

///|
async test "a stream above GOAWAY is sent again by libcurl on a new connection" {
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
      @mttp_core.Request::post(server.tls + "/goaway"),
      @mttp_core.SendOptions::default(),
    ) catch {
      // libcurl 7.88 does not send it again and reports a framing error:
      // not unsent, so mttp's Client resends only an idempotent request.
      e => {
        guard curl_version_num() < 0x080500 &&
          e is @mttp_core.TransportError(kind=Protocol, ..) else {
          fail("unexpected \{e.to_repr()}")
        }
        assert_false(e.is_unsent())
        return
      }
    }
    assert_eq(text(response), "after goaway")
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

///|
test "libcurl's version and features are readable" {
  assert_true(CurlBackend::libcurl_version().has_prefix("libcurl/"))
  // Either answer is fine; the call must not crash.
  CurlBackend::supports_http3() |> ignore
}

///|
async test "http3=true over a libcurl without HTTP/3 is refused before any I/O" {
  let backend = CurlBackend::new(http3=true, max_connection_age_ms=1500)
  defer backend.close()
  if CurlBackend::supports_http3() {
    return
  }
  let e = send_error(backend, @mttp_core.Request::get("https://127.0.0.1:1/"))
  guard e is @mttp_core.TransportError(kind=Invalid, phase=Pool, ..) else {
    fail("unexpected \{e.to_repr()}")
  }
}

///|
async test "a nonpositive timeout fails at once with Timeout in Pool" {
  let backend = CurlBackend::new(max_connection_age_ms=0)
  defer backend.close()
  let e = send_error(backend, @mttp_core.Request::get("http://127.0.0.1:1/"), options={
    ..@mttp_core.SendOptions::default(),
    timeout_ms: Some(0),
  })
  guard e is @mttp_core.TransportError(kind=Timeout(ms=0), phase=Pool, ..) else {
    fail("unexpected \{e.to_repr()}")
  }
}

///|
async test "only http and https URLs are sent" {
  let backend = CurlBackend::new()
  defer backend.close()
  let e = send_error(backend, @mttp_core.Request::get("ftp://127.0.0.1:1/x"))
  guard e is @mttp_core.TransportError(kind=Invalid, phase=Pool, ..) else {
    fail("unexpected \{e.to_repr()}")
  }
}

///|
async test "a stream body that ends before its declared length sends nothing" {
  let backend = CurlBackend::new()
  defer backend.close()
  let source = Pieces::{ pieces: [], next: 0, closed: 0, }
  let e = send_error(
    backend,
    @mttp_core.Request::post("http://127.0.0.1:1/").body_stream(
      source,
      length=5L,
    ),
  )
  // gaato/mttp_core's StreamBody reports the short stream; nothing was sent,
  // since port 1 would have refused the connection with Connect.
  guard e is @mttp_core.TransportError(kind=Protocol, ..) else {
    fail("unexpected \{e.to_repr()}")
  }
  assert_eq(source.closed, 1)
}

///|
async test "an empty stream body is sent as an empty body" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let source = Pieces::{ pieces: [], next: 0, closed: 0, }
    let response = backend.send(
      @mttp_core.Request::post(server.h2c + "/echo").body_stream(source),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(response.headers.get("x-received"), Some("0"))
    assert_eq(source.closed, 1)
  })
}

///|
async test "Insecure skips the certificate check" {
  with_server(server => {
    let backend = CurlBackend::new(trust=Insecure)
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.tls + "/hello"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(text(response), "hello")
  })
}

///|
async test "closing the backend fails the exchanges in flight with Closed" {
  with_server(server => {
    let backend = h2c_backend()
    let outcome : Ref[@mttp_core.TransportError?] = Ref(None)
    @async.with_task_group(group => {
      group.spawn_bg(() => {
        outcome.val = Some(
          send_error(backend, @mttp_core.Request::get(server.h2c + "/hang")),
        )
      })
      @async.sleep(300)
      backend.close()
    })
    guard outcome.val is Some(@mttp_core.TransportError(kind=Closed, ..)) else {
      fail("the in-flight send did not fail with Closed")
    }
  })
}

///|
async test "a body read after its end reads nothing" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.h2c + "/hello"),
      @mttp_core.SendOptions::default(),
    )
    guard response.body is Stream(stream) else { fail("not a stream") }
    let reader = stream.take()
    assert_eq(reader.read_some(), Some(b"hello"))
    assert_eq(reader.read_some(), None)
    assert_eq(reader.read_some(), None)
  })
}

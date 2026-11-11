///|
/// Answers with the request target, after the checks every backend makes
/// before I/O, and counts what it was asked to do.
priv struct Echo {
  mut sends : Int32
  seen : Array[@http.SendOptions]
}

///|
impl @http.Backend for Echo with fn send(self, request, options) {
  request.validate()
  options.validate()
  self.sends += 1
  self.seen.push(options)
  @http.Response::new(200, body=Bytes(@http.encode_utf8(request.url)))
}

///|
test "send options default to no deadline and a 64 MiB exchange" {
  let options = @http.SendOptions::default()
  assert_eq(options.timeout_ms, None)
  assert_eq(options.body, Exchange(max_bytes=67108864))
  debug_inspect(
    options,
    content=(
      #|{ timeout_ms: None, body: Exchange(max_bytes=67108864) }
    ),
  )
  assert_true(options != { ..options, body: Stream(idle_ms=None), })
}

///|
test "send options are refused before I/O, so unsent" {
  let base = @http.SendOptions::default()
  let cases : Array[(@http.SendOptions, @http.Kind?)] = [
    (base, None),
    ({ ..base, timeout_ms: Some(1), }, None),
    ({ ..base, timeout_ms: Some(0), }, Some(Timeout(ms=0))),
    ({ ..base, timeout_ms: Some(-5), }, Some(Timeout(ms=-5))),
    ({ ..base, body: Exchange(max_bytes=0), }, None),
    ({ ..base, body: Exchange(max_bytes=-1), }, Some(Invalid)),
    ({ ..base, body: Stream(idle_ms=None), }, None),
    ({ ..base, body: Stream(idle_ms=Some(1)), }, None),
    ({ ..base, body: Stream(idle_ms=Some(0)), }, Some(Invalid)),
    ({ ..base, body: Stream(idle_ms=Some(-1)), }, Some(Invalid)),
  ]
  for (options, expected) in cases {
    let got = try {
      options.validate()
      None
    } catch {
      @http.TransportError(kind~, phase=Pool, ..) as error => {
        assert_true(error.is_unsent())
        Some(kind)
      }
      _ => fail("refused outside phase Pool")
    }
    assert_eq(got, expected, msg=@debug.to_string(options))
  }
}

///|
test "a backend sends through the trait object and closes by default" {
  let echo = Echo::{ sends: 0, seen: [], }
  let backend : &@http.Backend = echo
  let options : @http.SendOptions = {
    timeout_ms: Some(250),
    body: Stream(idle_ms=Some(100)),
  }
  let response = @driver.run_sync(() => {
    backend.send(@http.Request::get("/ping"), options)
  })
  assert_eq(response.status, 200)
  assert_eq(response.body, Bytes(b"/ping"))
  assert_eq(echo.seen, [options])
  // The default close does nothing and may be called again.
  backend.close()
  backend.close()
  // An invalid request is refused before the backend does anything.
  let refused = try {
    let _ = @driver.run_sync(() => {
      backend.send(@http.Request::get("/a b"), @http.SendOptions::default())
    })
    false
  } catch {
    @http.TransportError(kind=Invalid, phase=Pool, ..) => true
    _ => false
  }
  assert_true(refused)
  assert_eq(echo.sends, 1)
}

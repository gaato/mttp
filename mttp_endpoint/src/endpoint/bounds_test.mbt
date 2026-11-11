///|
test "optional stream body roundtrips absence and present empty bodies through both interpreters" {
  let ep = @endpoint.endpoint
    .post("/upload")
    .input(@endpoint.stream_body().optional())
    .output(@endpoint.text_out())
  let server = ep.serve_public(reader => {
    match reader {
      None => Ok("absent")
      Some(reader) =>
        Ok("present:" + @http.read_bounded(reader, 20).length().to_string())
    }
  })
  let client = @client.Client::new(
    @client.from_handler(req => {
      server.dispatch(req, {}, @endpoint.DispatchContext::new())
    }),
    @sim.FakeClock::new(),
  )
  defer client.close()
  assert_eq(ep.request((), None).raw().body, @http.Empty)
  assert_eq(ep.request((), None).raw().headers.get("content-type"), None)
  let driver = @driver.Driver::new()
  driver.run(() => {
    assert_eq(ep.call(client, (), None), Ok(Ok("absent")))
    for chunks in [[], [b"abc"]] {
      let source = @sim.Feed::bytes(driver, chunks)
      assert_eq(
        ep.call(client, (), Some(source)).unwrap().unwrap(),
        if chunks.is_empty() {
          "present:0"
        } else {
          "present:3"
        },
      )
      assert_eq(source.closes(), 1)
    }
    // An explicit body still needs its media type, including zero bytes.
    let response = server.dispatch(
      @http.Request::post("/upload").body_bytes(b""),
      {},
      @endpoint.DispatchContext::new(),
    )
    assert_eq(response.status, 415)
    let response = server.dispatch(
      @http.Request::post("/upload")
      .header("content-type", "application/octet-stream")
      .body_bytes(b""),
      {},
      @endpoint.DispatchContext::new(),
    )
    assert_eq(response.status, 200)
    assert_eq(@client.read_body(response.body, 100), b"present:0")
    let response = server.dispatch(
      @http.Request::post("/upload").header("content-type", "text/plain"),
      {},
      @endpoint.DispatchContext::new(),
    )
    assert_eq(@client.read_body(response.body, 100), b"absent")
  })
}

///|
test "server buffered and streamed bodies admit the exact default and endpoint override" {
  let driver = @driver.Driver::new()
  for streamed in [false, true] {
    let buffered = @endpoint.body(@schema.raw_bytes).map(
      bytes => bytes.length(),
      _ => b"",
    )
    let endpoint = @endpoint.endpoint
      .post("/")
      .input(buffered)
      .output(@endpoint.json_out(@schema.jint.body()))
    let stream_endpoint = @endpoint.endpoint
      .post("/")
      .input(@endpoint.stream_body())
      .output(@endpoint.json_out(@schema.jint.body()))
    for overridden in [false, true] {
      let server = if streamed {
        (if overridden {
          stream_endpoint.max_body_bytes(3)
        } else {
          stream_endpoint
        }).serve_public(reader => {
          Ok(@http.read_bounded(reader, 2 * 1048576).length())
        })
      } else {
        (if overridden { endpoint.max_body_bytes(3) } else { endpoint }).serve_public(n => {
            Ok(n)
          },
        )
      }
      let limit = if overridden { 3 } else { 1048576 }
      for extra in [0, 1] {
        let source = @sim.Feed::bytes(driver, [Bytes::make(limit + extra, b'x')])
        driver.run(() => {
          let req = @http.Request::post("/").header(
            "content-type", "application/octet-stream",
          )
          let response = server.dispatch(
            { ..req, body: Stream(@http.StreamBody::new(source)), },
            {},
            @endpoint.DispatchContext::new(),
          )
          assert_eq(response.status, if extra == 0 { 200 } else { 413 })
          if extra == 1 {
            assert_eq(response.headers.get("connection"), Some("close"))
          }
        })
        assert_eq(source.closes(), 1)
      }
    }
  }
}

///|
test "adapter TooLarge keeps the smaller ceiling for buffered and streamed inputs" {
  let driver = @driver.Driver::new()
  let failures = []
  let ctx = @endpoint.DispatchContext::new(max_body_bytes=2, decode_failure=f => {
    failures.append(f.failures)
    @http.Response::new(413)
  })
  // The endpoint override replaces the default; the adapter still caps it.
  let buffered = @endpoint.endpoint
    .post("/")
    .max_body_bytes(10)
    .input(@endpoint.body(@schema.raw_bytes))
    .serve_public(_ => Ok(()))
  let streamed = @endpoint.endpoint
    .post("/")
    .max_body_bytes(10)
    .input(@endpoint.stream_body())
    .serve_public(reader => {
      // Even a handler catching its read error cannot turn it into success.
      ignore(@http.read_bounded(reader, 20)) catch {
        _ => ()
      }
      Ok(())
    })
  driver.run(() => {
    for server in [buffered, streamed] {
      let source = @sim.Feed::new(driver, [
        Chunk(b"abc"),
        Fail(
          @http.TransportError(
            kind=TooLarge(limit=3),
            phase=Body,
            detail="adapter ceiling",
          ),
        ),
      ])
      let req = @http.Request::post("/").header(
        "content-type", "application/octet-stream",
      )
      let response = server.dispatch(
        { ..req, body: Stream(@http.StreamBody::new(source)), },
        {},
        ctx,
      )
      assert_eq(response.status, 413)
      assert_eq(source.closes(), 1)
      assert_eq(response.headers.get("connection"), Some("close"))
    }
  })
  assert_eq(failures.length(), 2)
  for failure in failures {
    assert_true(
      failure.failure is @schema.DecodeFailure(kind=TooLarge(limit=3), ..),
    )
  }
}

///|
test "reported validation issues are capped at one hundred inside a single failure" {
  let codec = @schema.array(@schema.jint).body()
  let server = @endpoint.endpoint
    .post("/")
    .input(@endpoint.body(codec))
    .serve_public(_ => Ok(()))
  let request = @http.Request::post("/")
    .header("content-type", "application/json")
    .body_bytes(
      @http.encode_utf8("[" + Array::make(101, "false").join(",") + "]"),
    )
  let failures = []
  @driver.run_sync(() => {
    let response = server.dispatch(
      request,
      {},
      @endpoint.DispatchContext::new(),
    )
    assert_eq(response.status, 400)
    let value = @json.parse(
      @utf8.decode(@client.read_body(response.body, 65536)),
    )
    guard value is { "errors": Array(errors), .. } else {
      fail("missing errors")
    }
    assert_eq(errors.length(), 100)
    for limit in [1, 100] {
      let ctx = @endpoint.DispatchContext::new(max_issues=limit, decode_failure=f => {
        failures.append(f.failures)
        @http.Response::new(400)
      })
      assert_eq(server.dispatch(request, {}, ctx).status, 400)
    }
  })
  for i, failure in failures {
    guard failure.failure is @schema.DecodeFailure(kind=Invalid(issues), ..) else {
      fail("expected issues")
    }
    assert_eq(issues.length(), if i == 0 { 1 } else { 100 })
  }
}

///|
test "default failure policy distinguishes auth media validation and opaque handler errors" {
  let driver = @driver.Driver::new()
  let contexts = @endpoint.DispatchContext::new()
  let secured = @endpoint.endpoint
    .post("/")
    .security(@endpoint.bearer())
    .input(@endpoint.body(@schema.jint.body()))
    .serve(_ => Ok(()), (_, _) => Ok(()))
  driver.run(() => {
    let source = @sim.Feed::bytes(driver, [b"bad"])
    let response = secured.dispatch(
      {
        ..@http.Request::post("/"),
        body: Stream(@http.StreamBody::new(source)),
      },
      {},
      contexts,
    )
    assert_eq(response.status, 401)
    assert_eq(response.headers.get("www-authenticate"), Some("Bearer"))
    assert_eq(source.reads(), 0)
    assert_eq(source.closes(), 1)
    let req = @http.Request::post("/")
      .header("authorization", "Bearer token")
      .body_bytes(b"bad")
    assert_eq(secured.dispatch(req, {}, contexts).status, 415)
    assert_eq(
      secured.dispatch(
        req.header("content-type", "application/json"),
        {},
        contexts,
      ).status,
      400,
    )
    let server = @endpoint.endpoint
      .get("/")
      .serve_public(_ => raise Failure("private exception"))
    let response = server.dispatch(@http.Request::get("/"), {}, contexts)
    assert_eq(response.status, 500)
    assert_false(
      @utf8.decode(@client.read_body(response.body, 1000)).contains(
        "private exception",
      ),
    )
  })
}

///|
test "cancelling streamed input dispatch closes its body without invoking error policy" {
  let driver = @driver.Driver::new()
  let source = @sim.Feed::new(driver, [Wait(1000), Chunk(b"data")])
  let server = @endpoint.endpoint
    .post("/")
    .input(@endpoint.stream_body())
    .serve_public(reader => {
      ignore(reader.read_some())
      Ok(())
    })
  let errors = Ref(0)
  let ctx = @endpoint.DispatchContext::new(unhandled=(_, _) => {
    errors.val += 1
    @http.Response::new(500)
  })
  driver.run(() => {
    let task = driver.spawn(() => {
      let request = @http.Request::post("/").header(
        "content-type", "application/octet-stream",
      )
      ignore(
        server.dispatch(
          { ..request, body: Stream(@http.StreamBody::new(source)), },
          {},
          ctx,
        ),
      )
    })
    driver.pause()
    task.cancel()
    assert_false(task.wait())
  })
  assert_eq((source.closes(), source.cancellations(), errors.val), (1, 1, 0))
}

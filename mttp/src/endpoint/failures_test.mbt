///|
test "server bounds buffered streams records read failures and rejects reused streams" {
  assert_eq(@endpoint.DispatchContext::new().max_body_bytes, 1048576)
  let driver = @driver.Driver::new()
  let ep = @endpoint.endpoint
    .post("/")
    .input(@endpoint.body(@schema.raw_bytes))
    .max_body_bytes(3)
    .serve_public(_ => Ok(()))
  let streamed = @endpoint.endpoint
    .post("/")
    .input(@endpoint.stream_body())
    .serve_public(reader => {
      Ok(
        while reader.read_some() is Some(_) {

        },
      )
    })
  let contexts = []
  let ctx = @endpoint.DispatchContext::new(decode_failure=f => {
    contexts.push(f)
    @model.Response::new(400)
  })
  driver.run(() => {
    let request = @model.Request::post("/").header(
      "content-type", "application/octet-stream",
    )
    assert_eq(ep.dispatch(request.body_bytes(b"abc"), Map([]), ctx).status, 200)
    assert_eq(
      ep.dispatch(request.body_bytes(b"four"), Map([]), ctx).status,
      400,
    )
    let failed = @feed.Feed::new(driver, [
      Fail(@model.TransportError(kind=Network, phase=Body, detail="disconnect")),
    ])
    assert_eq(
      ep.dispatch(
        { ..request, body: Stream(@model.StreamBody::new(failed)), },
        Map([]),
        ctx,
      ).status,
      400,
    )
    assert_eq(failed.closes(), 1)
    let failed = @feed.Feed::new(driver, [
      Fail(@model.TransportError(kind=Network, phase=Body, detail="disconnect")),
    ])
    assert_eq(
      streamed.dispatch(
        { ..request, body: Stream(@model.StreamBody::new(failed)), },
        Map([]),
        ctx,
      ).status,
      400,
    )
    assert_eq(failed.closes(), 1)
    let source = @feed.Feed::bytes(driver, [b"abc"])
    let body = @model.StreamBody::new(source)
    ignore(body.take())
    assert_eq(
      streamed.dispatch({ ..request, body: Stream(body), }, Map([]), ctx).status,
      400,
    )
    assert_eq(source.closes(), 1)
    assert_eq(
      streamed.dispatch(request.body_bytes(b"abc"), Map([]), ctx).status,
      200,
    )
    assert_eq(streamed.dispatch(request, Map([]), ctx).status, 200)
    let signed = @endpoint.endpoint
      .post("/")
      .security(@endpoint.raw_body())
      .max_body_bytes(1)
      .serve(_ => Ok(()), (_, _) => Ok(()))
    assert_eq(
      signed.dispatch(request.body_bytes(b"abc"), Map([]), ctx).status,
      400,
    )
  })
  assert_eq(contexts.length(), 5)
  assert_true(
    contexts[0].failures[0].failure
    is @schema.DecodeFailure(kind=TooLarge(limit=3), ..),
  )
  assert_eq(contexts[4].stage, @endpoint.Security)
}

///|
test "invalid requests excessive queries and issue lists are rejected before the handler" {
  assert_eq(@endpoint.DispatchContext::new().max_issues, 100)
  let issues = []
  let ctx = @endpoint.DispatchContext::new(max_issues=1, decode_failure=f => {
    issues.push(f)
    @model.Response::new(400)
  })
  let input = @endpoint.pair(
    @endpoint.query("a", @schema.int),
    @endpoint.query("b", @schema.int),
  )
  let endpoint = @endpoint.endpoint
    .post("/")
    .input(input)
    .serve_public(_ => Ok(()))
  @driver.run_sync(() => {
    let bounded = @endpoint.endpoint
      .post("/")
      .input(@endpoint.query_params())
      .serve_public(_ => Ok(()))
    assert_eq(
      bounded.dispatch(
        @model.Request::post("/?" + Array::make(256, "q=1").join("&")),
        Map([]),
        ctx,
      ).status,
      200,
    )
    for
      url in [
        "/bad path",
        "http://[",
        "/?" + Array::make(257, "q=1").join("&"),
        "/",
      ] {
      assert_eq(
        endpoint.dispatch(@model.Request::post(url), Map([]), ctx).status,
        400,
      )
    }
  })
  assert_eq(issues.length(), 4)
  for issue in issues {
    assert_eq(issue.failures.length(), 1)
  }
}

///|
test "custom body stages without metadata still receive bounded body failures" {
  let input = @endpoint.Input::new(
    [],
    _ => @endpoint.Staged::after_body(_ => ()),
    (_, _) => (),
  )
  let endpoint = @endpoint.endpoint
    .post("/")
    .input(input)
    .max_body_bytes(0)
    .serve_public(_ => Ok(()))
  let failures = []
  let ctx = @endpoint.DispatchContext::new(decode_failure=f => {
    failures.append(f.failures)
    @model.Response::new(413)
  })
  @driver.run_sync(() => {
    assert_eq(
      endpoint.dispatch(
        @model.Request::post("/").body_bytes(b"x"),
        Map([]),
        ctx,
      ).status,
      413,
    )
  })
  assert_eq(failures.length(), 1)
  assert_eq(failures[0].atom.location, @endpoint.Derived)
}

///|
test "security decoding and authentication errors use their correct stage and policy" {
  let atom = @endpoint.Atom::new(
    RawBody,
    "signature",
    @schema.raw_bytes.schema(),
  )
  let custom = @endpoint.Input::new(
    [atom],
    _ => {
      @endpoint.Staged::after_body(_ => {
        raise @endpoint.InputErrors([
          @endpoint.InputFailure::new(
            atom,
            @schema.DecodeFailure(kind=Malformed, message="invalid signature"),
          ),
        ])
      })
    },
    (_ : Unit, sink) => sink.set_body(Bytes(b"signed")),
  )
  let contexts = []
  let ctx = @endpoint.DispatchContext::new(decode_failure=f => {
    contexts.push(f)
    @model.Response::new(400)
  })
  let endpoint = @endpoint.endpoint
    .post("/")
    .security(custom)
    .serve(_ => Ok(()), (_, _) => Ok(()))
  @driver.run_sync(() => {
    assert_eq(
      endpoint.dispatch(@model.Request::post("/"), Map([]), ctx).status,
      400,
    )
    let auth = @endpoint.endpoint
      .get("/")
      .security(@endpoint.bearer())
      .serve(_ => raise Failure("auth failed"), (_ : Unit, _) => Ok(()))
    assert_eq(
      auth.dispatch(
        @model.Request::get("/").header("authorization", "Bearer token"),
        Map([]),
        ctx,
      ).status,
      500,
    )
  })
  assert_eq(contexts[0].stage, @endpoint.Security)
}

///|
test "invalid error-policy streams are closed and retain route metadata on fallback" {
  let driver = @driver.Driver::new()
  let endpoint = @endpoint.endpoint
    .get("/failed")
    .serve_public(_ => raise Failure("handler"))
  driver.run(() => {
    for recover in [true, false] {
      let source = @feed.Feed::bytes(driver, [b"bad"])
      let stream = @model.StreamBody::new(source)
      ignore(stream.take())
      let calls = Ref(0)
      let context = @endpoint.DispatchContext::new(unhandled=(_, _) => {
        calls.val += 1
        if recover && calls.val == 2 {
          @model.Response::new(502)
        } else {
          @model.Response::new(500, body=Stream(stream))
        }
      })
      let response = endpoint.dispatch(
        @model.Request::get("/failed"),
        Map([]),
        context,
      )
      assert_eq(response.status, if recover { 502 } else { 500 })
      assert_eq(
        response.attributes.get(@endpoint.route_template),
        Some("/failed"),
      )
      assert_eq(source.closes(), 1)
    }
  })
}

///|
test "output status validation and bodyless statuses are enforced by the interpreter" {
  @driver.run_sync(() => {
    for status in [0, 204, 304, 600] {
      let endpoint = @endpoint.endpoint
        .get("/")
        .output(@endpoint.text_out().and_status())
        .serve_public(_ => Ok(("body", status)))
      let response = endpoint.dispatch(
        @model.Request::get("/"),
        Map([]),
        @endpoint.DispatchContext::new(),
      )
      assert_eq(
        response.status,
        if status < 200 || status > 599 {
          500
        } else {
          status
        },
      )
      assert_eq(response.body, @model.Empty)
    }
    let empty : @endpoint.Out[Unit, @client.Buffered] = @endpoint.one_of([])
    let endpoint = @endpoint.endpoint
      .get("/")
      .output(empty)
      .serve_public(_ => Ok(()))
    assert_eq(
      endpoint.dispatch(
        @model.Request::get("/"),
        Map([]),
        @endpoint.DispatchContext::new(),
      ).status,
      500,
    )
  })
}

///|
test "failed event producers close their sources and in-flight request bodies" {
  let driver = @driver.Driver::new()
  let closed = Ref(0)
  let endpoint = @endpoint.endpoint
    .post("/")
    .output(@endpoint.sse_out(@schema.jint))
    .serve_public(_ => {
      Ok(
        @endpoint.EventStream::from_pull(() => raise Failure("producer"), () => {
          closed.val += 1
        }),
      )
    })
  driver.run(() => {
    let source = @feed.Feed::bytes(driver, [b"request"])
    let response = endpoint.dispatch(
      {
        ..@model.Request::post("/"),
        body: Stream(@model.StreamBody::new(source)),
      },
      Map([]),
      @endpoint.DispatchContext::new(),
    )
    let failed = try {
      ignore(@client.read_body(response.body, 100))
      false
    } catch {
      @model.TransportError(kind=Protocol, ..) => true
      _ => false
    }
    assert_true(failed)
    assert_eq(source.closes(), 1)
  })
  assert_eq(closed.val, 1)
}

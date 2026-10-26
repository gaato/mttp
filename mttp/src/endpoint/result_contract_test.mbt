///|
test "stream requests decode declared errors before handoff and retain bounded failures" {
  let response = Ref(
    @model.Response::new(
      400,
      headers=@model.Headers::of([("content-type", "text/plain")]),
      body=Bytes(b"denied"),
    ),
  )
  let client = @client.Client::new(
    @client.from_fn((_, _) => response.val),
    @fake.FakeClock::new(),
  )
  let ep = @endpoint.endpoint
    .get("/")
    .errors(@endpoint.text_out(status=400))
    .output(@endpoint.text_out())
  let delivered = Ref(0)
  @driver.run_sync(() => {
    let request = ep.stream_request((), (), value => {
      delivered.val += 1
      value
    })
    assert_eq(request.send(client).body, Ok(Err("denied")))
    assert_eq(delivered.val, 0)
    response.val = @model.Response::new(
      200,
      headers=@model.Headers::of([("content-type", "text/plain")]),
      body=Bytes(b"success"),
    )
    assert_eq(request.send(client).body, Ok(Ok("success")))
    assert_eq(delivered.val, 1)
    response.val = { ..response.val, body: Bytes(b"\xff"), }
    assert_true(
      request.send(client).body is Err(@client.Deserialization(_, ..)),
    )
    assert_eq(delivered.val, 1)
    response.val = @model.Response::new(
      400,
      headers=@model.Headers::of([("content-type", "application/json")]),
      body=Bytes(Bytes::make(2 * 1048576, b'x')),
    )
    let json = @endpoint.endpoint
      .get("/")
      .errors(@endpoint.json_out(@schema.jint.body(), status=400))
      .output(@endpoint.text_out())
    guard json
      .stream_request((), (), _ => {
        fail("error reached consumer")
        ()
      })
      .send(client).body
      is Err(@client.Deserialization(head, body~, ..)) else {
      fail("invalid declared error accepted")
    }
    assert_eq(head.status, 400)
    assert_eq(body.length(), 1048576)
  })
}

///|
test "stream callbacks retain user exceptions and never become response failures" {
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      @model.Response::new(
        200,
        headers=@model.Headers::of([("content-type", "text/plain")]),
        body=Bytes(b"value"),
      )
    }),
    @fake.FakeClock::new(),
  )
  let ep = @endpoint.endpoint.get("/").output(@endpoint.text_out())
  let original = Failure("user callback")
  @driver.run_sync(() => {
    try {
      ignore(
        ep
        .stream_request((), (), _ => {
          raise original
          ()
        })
        .send(client),
      )
      fail("user exception lost")
    } catch {
      Failure(_) as error => assert_true(physical_equal(original, error))
      error => raise error
    }
  })
}

///|
test "authentication errors are ordinary declared values before the handler runs" {
  let ep = @endpoint.endpoint
    .post("/")
    .errors(@endpoint.text_out(status=401))
    .output(@endpoint.text_out())
  let called = Ref(false)
  let server = ep.serve(_ => Err("denied"), (_ : Unit, _) => {
    called.val = true
    Ok("ok")
  })
  @driver.run_sync(() => {
    let response = server.dispatch(
      @model.Request::post("/"),
      Map([]),
      @endpoint.DispatchContext::new(),
    )
    assert_eq(response.status, 401)
    assert_eq(@client.read_body(response.body, 1024), b"denied")
    assert_false(called.val)
  })
  let errors = @endpoint.one_of([
    @endpoint.json_variant(400, @schema.text_body).contramap(
      (value : String) => if value == "known" { Some(value) } else { None },
      value => value,
    ),
  ])
  let server = @endpoint.endpoint
    .get("/")
    .errors(errors)
    .serve(_ => Err("unknown"), (_ : Unit, _) => {
      called.val = true
      Ok(())
    })
  @driver.run_sync(() => {
    assert_eq(
      server.dispatch(
        @model.Request::get("/"),
        Map([]),
        @endpoint.DispatchContext::new(),
      ).status,
      500,
    )
    assert_false(called.val)
  })
}

///|
test "unknown buffered and stream representations stop at the diagnostic bound" {
  for streaming in [false, true] {
    let driver = @driver.Driver::new()
    let source = @feed.Feed::bytes(driver, [Bytes::make(2 * 1048576, b'x')])
    let client = @client.Client::new(
      @client.from_fn((_, _) => {
        @model.Response::new(
          200,
          body=Stream(@model.StreamBody::new(source)),
          headers=@model.Headers::of([("content-type", "image/unexpected")]),
        )
      }),
      @fake.FakeClock::new(),
    )
    let buffered = @endpoint.endpoint.get("/").output(@endpoint.text_out())
    let streamed = @endpoint.endpoint
      .get("/")
      .output(@endpoint.sse_out(@schema.jint))
    let consumed = Ref(false)
    let rejected = driver.run(() => {
      if streaming {
        streamed.stream_request((), (), _ => consumed.val = true).send(client).body.map(_ => {
            ()
          },
        )
      } else {
        buffered.request((), ()).send(client).body.map(_ => ())
      }
    })
    guard rejected is Err(@client.UnexpectedStatus(head, body~)) else {
      fail("unknown representation was accepted")
    }
    assert_eq(head.status, 200)
    assert_eq(body.length(), 1048576)
    assert_eq((source.closes(), source.reads(), consumed.val), (1, 1, false))
  }
}

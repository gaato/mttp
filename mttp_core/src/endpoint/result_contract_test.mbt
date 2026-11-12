///|
test "stream requests decode declared errors before handoff and retain bounded failures" {
  let response = Ref(
    @mttp_core.Response::new(
      400,
      headers=@mttp_core.Headers::of([("content-type", "text/plain")]),
      body=Bytes(b"denied"),
    ),
  )
  let client = @client.Client::new(
    @client.from_fn((_, _) => response.val),
    @sim.FakeClock::new(),
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
    response.val = @mttp_core.Response::new(
      200,
      headers=@mttp_core.Headers::of([("content-type", "text/plain")]),
      body=Bytes(b"success"),
    )
    assert_eq(request.send(client).body, Ok(Ok("success")))
    assert_eq(delivered.val, 1)
    response.val = { ..response.val, body: Bytes(b"\xff"), }
    assert_true(
      request.send(client).body is Err(@client.Deserialization(_, ..)),
    )
    assert_eq(delivered.val, 1)
    response.val = @mttp_core.Response::new(
      400,
      headers=@mttp_core.Headers::of([("content-type", "application/json")]),
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
      @mttp_core.Response::new(
        200,
        headers=@mttp_core.Headers::of([("content-type", "text/plain")]),
        body=Bytes(b"value"),
      )
    }),
    @sim.FakeClock::new(),
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
test "call_with decodes buffered outputs before retry observation and invokes its callback once" {
  let events = []
  let codec = @schema.BodyCodec::new(
    "text/plain",
    bytes => {
      events.push("decode")
      @schema.text_body.decode(bytes)
    },
    value => @schema.text_body.encode(value),
    @schema.string.schema(),
  )
  let calls = Ref(0)
  let client = @client.Client::new(
    @client.from_handler(_ => {
      calls.val += 1
      @mttp_core.Response::new(
        if calls.val == 1 {
          503
        } else {
          200
        },
        headers=@mttp_core.Headers::of([("content-type", "text/plain")]),
        body=Bytes(b"ok"),
      )
    }),
    @sim.FakeClock::new(),
    retry=@client.RetryPolicy::conservative(),
    observer=_ => events.push("observe"),
  )
  defer client.close()
  let ep = @endpoint.endpoint
    .get("/")
    .output(@endpoint.json_out(codec).and_status())
  @driver.run_sync(() => {
    assert_eq(
      ep.call_with(client, (), (), value => {
        events.push("consume")
        value
      }),
      Ok(Ok(("ok", 200))),
    )
  })
  assert_eq(events, ["decode", "observe", "decode", "observe", "consume"])
}

///|
test "SSE callbacks preserve unknown exceptions and close their borrowed source" {
  let driver = @driver.Driver::new()
  let source = @sim.Feed::bytes(driver, [b"data: 1\n\n"])
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @mttp_core.Response::new(
        200,
        headers=@mttp_core.Headers::of([("content-type", "text/event-stream")]),
        body=Stream(@mttp_core.StreamBody::new(source)),
      )
    }),
    @sim.FakeClock::new(),
  )
  defer client.close()
  let original = Failure("consumer")
  let ep = @endpoint.endpoint.get("/").output(@endpoint.sse_out(@schema.jint))
  driver.run(() => {
    try {
      ignore(
        ep.call_with(client, (), (), _ => {
          raise original
          ()
        }),
      )
      fail("consumer exception lost")
    } catch {
      Failure(_) as error => assert_true(physical_equal(error, original))
      error => raise error
    }
  })
  assert_eq((source.closes(), source.reads()), (1, 0))
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
      @mttp_core.Request::post("/"),
      Map([]),
      @endpoint.DispatchContext::new(),
    )
    assert_eq(response.status, 401)
    assert_eq(response.body.read_all(max=1024), b"denied")
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
        @mttp_core.Request::get("/"),
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
    let source = @sim.Feed::bytes(driver, [Bytes::make(2 * 1048576, b'x')])
    let client = @client.Client::new(
      @client.from_fn((_, _) => {
        @mttp_core.Response::new(
          200,
          body=Stream(@mttp_core.StreamBody::new(source)),
          headers=@mttp_core.Headers::of([("content-type", "image/unexpected")]),
        )
      }),
      @sim.FakeClock::new(),
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

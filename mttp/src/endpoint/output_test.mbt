///|
test "dynamic body outputs require a content type and cookie outputs require one named cookie" {
  let response = Ref(@model.Response::new(200, body=Bytes(b"data")))
  let client = @client.Client::new(
    @client.from_fn((_, _) => response.val),
    @fake.FakeClock::new(),
  )
  let dynamic = @endpoint.endpoint.get("/").output(@endpoint.body_out())
  let cookies = @endpoint.endpoint
    .get("/")
    .output(@endpoint.text_out().set_cookie("id"))
  @driver.run_sync(() => {
    let refused = try {
      ignore(dynamic.call(client, (), ()))
      false
    } catch {
      @client.Deserialization(_, ..) => true
      _ => false
    }
    assert_true(refused)
    response.val = {
      ..response.val,
      headers: @model.Headers::of([("content-type", "text/plain")]),
    }
    let refused = try {
      ignore(cookies.call(client, (), ()))
      false
    } catch {
      @client.Deserialization(_, ..) => true
      _ => false
    }
    assert_true(refused)
  })
  client.close()
}

///|
test "streaming metadata roundtrips dynamic status cookies and typed header failures" {
  let output = @endpoint.sse_out(@schema.jint)
    .and_status()
    .set_cookie("session")
    .and_header("x-count", @schema.int)
  let ep = @endpoint.endpoint.get("/").output(output)
  let server = ep.serve_public(_ => {
    (((@endpoint.EventStream::from_array([7]), 202), "value; Secure"), 3)
  })
  let headers = Ref(@model.Headers::empty())
  let corrupt = Ref(false)
  let client = @client.Client::new(
    @client.from_fn((req, _) => {
      let response = server.dispatch(
        req,
        Map([]),
        @endpoint.DispatchContext::new(),
      )
      if corrupt.val {
        { ..response, headers: headers.val, }
      } else {
        response
      }
    }),
    @fake.FakeClock::new(),
  )
  @driver.run_sync(() => {
    ep.call_with(client, (), (), value => {
      assert_eq(value.1, 3)
      assert_eq(value.0.1, "value; Secure")
      assert_eq(value.0.0.1, 202)
      let events = []
      value.0.0.0.each(event => events.push(event))
      assert_eq(events, [7])
    })
    corrupt.val = true
    for
      fields in [
        [("x-count", "3")],
        [
          ("x-count", "3"),
          ("set-cookie", "session=a"),
          ("set-cookie", "session=b"),
        ],
        [("x-count", "bad"), ("set-cookie", "session=a")],
      ] {
      headers.val = @model.Headers::of(
        [("content-type", "text/event-stream"), ..fields],
      )
      let refused = try {
        ep.call_with(client, (), (), _ => ())
        false
      } catch {
        @client.Deserialization(_, ..) => true
        _ => false
      }
      assert_true(refused)
    }
  })
  client.close()
}

///|
test "nested output projections preserve their inner selection and dynamic status" {
  let positive = @endpoint.json_variant(200, @schema.jint.body())
    .and_status()
    .contramap(
      (value : (Int32, Int32)) => if value.0 > 0 { Some(value) } else { None },
      value => value,
    )
    .contramap((value : (Int32, Int32)) => Some(value), value => value)
  let fallback = @endpoint.json_variant(400, @schema.jint.body()).contramap(
    (value : (Int32, Int32)) => Some(value.0),
    value => (value, 400),
  )
  let ep = @endpoint.endpoint
    .get("/")
    .output(@endpoint.one_of([positive, fallback]))
  @driver.run_sync(() => {
    for (value, expected) in [((1, 201), 201), ((-1, 201), 400)] {
      let response = ep
        .serve_public(_ => value)
        .dispatch(
          @model.Request::get("/"),
          Map([]),
          @endpoint.DispatchContext::new(),
        )
      assert_eq(response.status, expected)
    }
  })
}

///|
test "buffered variants try matching decoders in order and reject unknown representations" {
  let output = @endpoint.one_of([
    @endpoint.json_variant(
      200,
      @schema.jint.validate(@schema.minimum(10)).body(),
    ),
    @endpoint.json_variant(200, @schema.jint.body()).fixed_header(
      "x-fixed", "yes",
    ),
  ])
  let ep = @endpoint.endpoint.get("/").output(output)
  let response = Ref(
    @model.Response::new(
      200,
      headers=@model.Headers::of([("content-type", "application/json")]),
      body=Bytes(b"1"),
    ),
  )
  let client = @client.Client::new(
    @client.from_fn((_, _) => response.val),
    @fake.FakeClock::new(),
  )
  @driver.run_sync(() => {
    assert_eq(ep.call(client, (), ()), 1)
    assert_eq(ep.call_with(client, (), (), value => value + 1), 2)
    response.val = { ..response.val, body: @model.Bytes(b"bad"), }
    let failed = try {
      ignore(ep.call(client, (), ()))
      false
    } catch {
      @client.Deserialization(_, ..) => true
      _ => false
    }
    assert_true(failed)
    response.val = @model.Response::new(200)
    let failed = try {
      ignore(ep.call(client, (), ()))
      false
    } catch {
      @client.UnexpectedStatus(_, ..) => true
      _ => false
    }
    assert_true(failed)
    let server = ep.serve_public(_ => 12)
    assert_eq(
      server.dispatch(
        @model.Request::get("/"),
        Map([]),
        @endpoint.DispatchContext::new(),
      ).status,
      200,
    )
    let fixed = @endpoint.endpoint
      .get("/")
      .output(
        @endpoint.one_of([
          @endpoint.empty_variant(200).fixed_header("x-fixed", "yes"),
        ]),
      )
      .serve_public(_ => ())
    assert_eq(
      fixed.dispatch(
        @model.Request::get("/"),
        Map([]),
        @endpoint.DispatchContext::new(),
      ).headers.get("x-fixed"),
      Some("yes"),
    )
  })
  client.close()
}

///|
test "typed response headers fail when absent or malformed" {
  let ep = @endpoint.endpoint
    .get("/")
    .output(@endpoint.text_out().and_header("x-int", @schema.int))
  let response = Ref(
    @model.Response::new(
      200,
      headers=@model.Headers::of([("content-type", "text/plain")]),
      body=Bytes(b"text"),
    ),
  )
  let client = @client.Client::new(
    @client.from_fn((_, _) => response.val),
    @fake.FakeClock::new(),
  )
  @driver.run_sync(() => {
    for
      headers in [
        response.val.headers,
        response.val.headers.add("x-int", "bad"),
      ] {
      response.val = { ..response.val, headers, }
      let failed = try {
        ignore(ep.call(client, (), ()))
        false
      } catch {
        @client.Deserialization(_, ..) => true
        _ => false
      }
      assert_true(failed)
    }
    let no_body = @endpoint.endpoint.get("/").output(@endpoint.no_content())
    response.val = @model.Response::new(204)
    no_body.call(client, (), ())
    no_body.call_with(client, (), (), _ => ())
    response.val = @model.Response::new(
      204,
      headers=@model.Headers::of([("content-type", "text/plain")]),
    )
    let failed = try {
      no_body.call(client, (), ())
      false
    } catch {
      @client.UnexpectedStatus(_, ..) => true
      _ => false
    }
    assert_true(failed)
  })
  client.close()
}

///|
test "SSE malformed payloads and missing streaming headers close sources" {
  let ep = @endpoint.endpoint
    .get("/")
    .output(@endpoint.sse_out(@schema.jint).and_header("x-int", @schema.int))
  let response = Ref(
    @model.Response::new(
      200,
      headers=@model.Headers::of([("content-type", "text/event-stream")]),
      body=Bytes(b"data: 1\n\n"),
    ),
  )
  let client = @client.Client::new(
    @client.from_fn((_, _) => response.val),
    @fake.FakeClock::new(),
  )
  @driver.run_sync(() => {
    let failed = try {
      ep.call_with(client, (), (), value => value.0.each(_ => ()))
      false
    } catch {
      @client.Deserialization(_, ..) => true
      _ => false
    }
    assert_true(failed)
    response.val = {
      ..response.val,
      headers: response.val.headers.add("x-int", "1"),
    }
    ep.call_with(client, (), (), value => {
      assert_eq(value.1, 1)
      value.0.each(value => assert_eq(value, 1))
    })
    for bytes in [b"data: invalid\n\n", b"data: \"text\"\n\n"] {
      response.val = { ..response.val, body: @model.Bytes(bytes), }
      let failed = try {
        ep.call_with(client, (), (), value => value.0.each(_ => ()))
        false
      } catch {
        @client.Deserialization(_, ..) => true
        _ => false
      }
      assert_true(failed)
    }
    let buffered = try {
      ignore(ep.call(client, (), ()))
      false
    } catch {
      @client.Deserialization(_, ..) => true
      _ => false
    }
    assert_true(buffered)
  })
  client.close()
}

///|
test "event streams close once after callbacks fail and custom event metadata is encoded" {
  let closes = Ref(0)
  let source = @endpoint.EventStream::from_pull(() => Some(1), () => {
    closes.val += 1
  })
  @driver.run_sync(() => {
    let failed = try {
      source.each(_ => raise Failure("stop"))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
    source.each(_ => raise Failure("closed source read again"))
  })
  source.close()
  assert_eq(closes.val, 1)
  let endpoint = @endpoint.endpoint
    .get("/")
    .output(
      @endpoint.sse_out(@schema.jint, to_event=value => @sse.SseEvent::{
        event: "update",
        data: value.to_string(),
        id: Some("cursor"),
        retry: Some(100),
      }),
    )
    .serve_public(_ => @endpoint.EventStream::from_array([1]))
  @driver.run_sync(() => {
    let response = endpoint.dispatch(
      @model.Request::get("/"),
      Map([]),
      @endpoint.DispatchContext::new(),
    )
    let bytes = @client.read_body(response.body, 1024)
    let parser = @sse.SseParser::new()
    let events = parser.feed(bytes)
    assert_eq(events[0].id, Some("cursor"))
    assert_eq(events[0].event, "update")
  })
}

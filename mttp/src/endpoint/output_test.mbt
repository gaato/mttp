///|
test "dynamic body outputs require a content type and cookie outputs require one named cookie" {
  let response = Ref(@mttp.Response::new(200, body=Bytes(b"data")))
  let client = @client.Client::new(
    @client.from_fn((_, _) => response.val),
    @sim.FakeClock::new(),
  )
  let dynamic = @endpoint.endpoint.get("/").output(@endpoint.body_out())
  let cookies = @endpoint.endpoint
    .get("/")
    .output(@endpoint.text_out().set_cookie("id"))
  @driver.run_sync(() => {
    let refused = dynamic.call(client, (), ())
      is Err(@client.Deserialization(_, ..))
    assert_true(refused)
    response.val = {
      ..response.val,
      headers: @mttp.Headers::of([("content-type", "text/plain")]),
    }
    let refused = cookies.call(client, (), ())
      is Err(@client.Deserialization(_, ..))
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
    Ok((((@endpoint.EventStream::from_array([7]), 202), "value; Secure"), 3))
  })
  let headers = Ref(@mttp.Headers::empty())
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
    @sim.FakeClock::new(),
  )
  @driver.run_sync(() => {
    ep
    .call_with(client, (), (), value => {
      assert_eq(value.1, 3)
      assert_eq(value.0.1, "value; Secure")
      assert_eq(value.0.0.1, 202)
      let events = []
      value.0.0.0.each(event => events.push(event))
      assert_eq(events, [7])
    })
    .unwrap()
    .unwrap()
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
      headers.val = @mttp.Headers::of(
        [("content-type", "text/event-stream"), ..fields],
      )
      let refused = ep.call_with(client, (), (), _ => ())
        is Err(@client.Deserialization(_, ..))
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
        .serve_public(_ => Ok(value))
        .dispatch(
          @mttp.Request::get("/"),
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
    @mttp.Response::new(
      200,
      headers=@mttp.Headers::of([("content-type", "application/json")]),
      body=Bytes(b"1"),
    ),
  )
  let client = @client.Client::new(
    @client.from_fn((_, _) => response.val),
    @sim.FakeClock::new(),
  )
  @driver.run_sync(() => {
    assert_eq(ep.call(client, (), ()).unwrap().unwrap(), 1)
    assert_eq(
      ep.call_with(client, (), (), value => value + 1).unwrap().unwrap(),
      2,
    )
    response.val = { ..response.val, body: @mttp.Bytes(b"bad"), }
    let failed = ep.call(client, (), ()) is Err(@client.Deserialization(_, ..))
    assert_true(failed)
    response.val = @mttp.Response::new(200)
    let failed = ep.call(client, (), ()) is Err(@client.UnexpectedStatus(_, ..))
    assert_true(failed)
    let server = ep.serve_public(_ => Ok(12))
    assert_eq(
      server.dispatch(
        @mttp.Request::get("/"),
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
      .serve_public(_ => Ok(()))
    assert_eq(
      fixed.dispatch(
        @mttp.Request::get("/"),
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
    @mttp.Response::new(
      200,
      headers=@mttp.Headers::of([("content-type", "text/plain")]),
      body=Bytes(b"text"),
    ),
  )
  let client = @client.Client::new(
    @client.from_fn((_, _) => response.val),
    @sim.FakeClock::new(),
  )
  @driver.run_sync(() => {
    for
      headers in [
        response.val.headers,
        response.val.headers.add("x-int", "bad"),
      ] {
      response.val = { ..response.val, headers, }
      let failed = ep.call(client, (), ())
        is Err(@client.Deserialization(_, ..))
      assert_true(failed)
    }
    let no_body = @endpoint.endpoint.get("/").output(@endpoint.no_content())
    response.val = @mttp.Response::new(204)
    no_body.call(client, (), ()).unwrap().unwrap()
    no_body.call_with(client, (), (), _ => ()).unwrap().unwrap()
    response.val = @mttp.Response::new(
      204,
      headers=@mttp.Headers::of([("content-type", "text/plain")]),
    )
    let failed = no_body.call(client, (), ())
      is Err(@client.UnexpectedStatus(_, ..))
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
    @mttp.Response::new(
      200,
      headers=@mttp.Headers::of([("content-type", "text/event-stream")]),
      body=Bytes(b"data: 1\n\n"),
    ),
  )
  let client = @client.Client::new(
    @client.from_fn((_, _) => response.val),
    @sim.FakeClock::new(),
  )
  @driver.run_sync(() => {
    let failed = ep.call_with(client, (), (), value => value.0.each(_ => ()))
      is Err(@client.Deserialization(_, ..))
    assert_true(failed)
    response.val = {
      ..response.val,
      headers: response.val.headers.add("x-int", "1"),
    }
    ep
    .call_with(client, (), (), value => {
      assert_eq(value.1, 1)
      value.0.each(value => assert_eq(value, 1))
    })
    .unwrap()
    .unwrap()
    for bytes in [b"data: invalid\n\n", b"data: \"text\"\n\n"] {
      response.val = { ..response.val, body: @mttp.Bytes(bytes), }
      let failed = ep.call_with(client, (), (), value => value.0.each(_ => ()))
        is Err(@client.Deserialization(_, ..))
      assert_true(failed)
      // Stream-only request rejection is checked by negative type fixtures.

    }
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
      @endpoint.sse_out(@schema.jstring, meta=value => {
        if value == "a" {
          @endpoint.SseMeta::new(id="cursor", event="update", retry=100)
        } else {
          @endpoint.SseMeta::new()
        }
      }),
    )
    .serve_public(_ => Ok(@endpoint.EventStream::from_array(["a", "b"])))
  @driver.run_sync(() => {
    let response = endpoint.dispatch(
      @mttp.Request::get("/"),
      Map([]),
      @endpoint.DispatchContext::new(),
    )
    // The library writes the codec's JSON as data, beside the meta's fields.
    assert_eq(
      @client.read_body(response.body, 1024),
      b"event: update\nid: cursor\nretry: 100\ndata: \"a\"\n\ndata: \"b\"\n\n",
    )
  })
}

///|
test "SSE responses end at server shutdown and other outputs drain" {
  let context = @endpoint.DispatchContext::new()
  let events = @endpoint.endpoint
    .get("/")
    .output(@endpoint.sse_out(@schema.jint).and_header("x-int", @schema.int))
    .serve_public(_ => Ok((@endpoint.EventStream::from_array([1]), 2)))
  let text = @endpoint.endpoint
    .get("/")
    .output(@endpoint.text_out())
    .serve_public(_ => Ok("text"))
  @driver.run_sync(() => {
    let response = events.dispatch(@mttp.Request::get("/"), Map([]), context)
    assert_eq(response.attributes.get(@mttp.close_on_shutdown), Some(true))
    assert_eq(response.headers.get("x-int"), Some("2"))
    response.close()
    let response = text.dispatch(@mttp.Request::get("/"), Map([]), context)
    assert_eq(response.attributes.get(@mttp.close_on_shutdown), None)
  })
}

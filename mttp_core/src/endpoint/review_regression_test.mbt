///|
test "overlapping output and declared error decoders roundtrip through call and call_with" {
  let ep = @endpoint.endpoint
    .get("/")
    .output(@endpoint.json_out(@schema.jint.body()).and_status())
    .errors(@endpoint.json_out(@schema.jstring.body(), status=400))
  let server = ep.serve_public(_ => Err("denied"))
  let client = @client.Client::new(
    @client.from_handler(req => {
      server.dispatch(req, {}, @endpoint.DispatchContext::new())
    }),
    @sim.FakeClock::new(),
  )
  defer client.close()
  @driver.run_sync(() => {
    assert_eq(ep.call(client, (), ()), Ok(Err("denied")))
    assert_eq(
      ep.call_with(client, (), (), value => {
        fail("declared error reached output callback")
        value
      }),
      Ok(Err("denied")),
    )
  })
}

///|
test "call_with tries declared error after overlapping buffered output fails" {
  let ep = @endpoint.endpoint
    .get("/")
    .output(@endpoint.json_out(@schema.jint.body()).and_status())
    .errors(@endpoint.json_out(@schema.jstring.body(), status=400))
  let server = ep.serve_public(_ => Err("denied"))
  let client = @client.Client::new(
    @client.from_handler(req => {
      server.dispatch(req, {}, @endpoint.DispatchContext::new())
    }),
    @sim.FakeClock::new(),
  )
  defer client.close()
  @driver.run_sync(() => {
    assert_eq(
      ep.call_with(client, (), (), _ => {
        fail("declared error reached output callback")
        ()
      }),
      Ok(Err("denied")),
    )
  })
}

///|
test "overlapping candidates reuse one bounded body in output then error declaration order" {
  let events = []
  let codec = (name, accepts : Ref[Bool]) => {
    @schema.BodyCodec::new(
      "text/plain",
      bytes => {
        events.push(name)
        if !accepts.val {
          raise @schema.DecodeFailure(kind=Malformed, message=name)
        }
        @schema.text_body.decode(bytes)
      },
      @mttp_core.encode_utf8,
      @schema.string.schema(),
    )
  }
  let output1 = Ref(false)
  let output2 = Ref(false)
  let error1 = Ref(false)
  let error2 = Ref(true)
  let ep = @endpoint.endpoint
    .get("/")
    .output(
      @endpoint.one_of([
        @endpoint.json_variant(400, codec("output1", output1)),
        @endpoint.json_variant(400, codec("output2", output2)),
      ]),
    )
    .errors(
      @endpoint.one_of([
        @endpoint.json_variant(400, codec("error1", error1)),
        @endpoint.json_variant(400, codec("error2", error2)),
      ]),
    )
  let d = @driver.Driver::new()
  let feeds = []
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      let feed = @sim.Feed::bytes(d, [b"de", b"nied"])
      feeds.push(feed)
      @mttp_core.Response::new(
        400,
        headers=@mttp_core.Headers::of([("content-type", "text/plain")]),
        body=Stream(@mttp_core.StreamBody::new(feed)),
      )
    }),
    @sim.FakeClock::new(),
    max_body_bytes=6,
  )
  defer client.close()
  d.run(() => {
    assert_eq(ep.call(client, (), ()), Ok(Err("denied")))
    assert_eq(events, ["output1", "output2", "error1", "error2"])
    events.clear()
    assert_eq(ep.call_with(client, (), (), value => value), Ok(Err("denied")))
    assert_eq(events, ["output1", "output2", "error1", "error2"])
    events.clear()
    output2.val = true
    assert_eq(ep.call(client, (), ()), Ok(Ok("denied")))
    assert_eq(events, ["output1", "output2"])
    events.clear()
    output1.val = true
    assert_eq(ep.call_with(client, (), (), value => value), Ok(Ok("denied")))
    assert_eq(events, ["output1"])
  })
  for feed in feeds {
    assert_eq(feed.reads(), 3)
    assert_eq(feed.closes(), 1)
  }
}

///|
test "all overlapping decoders failing preserve output failure and bounded diagnostic bytes" {
  let failed = name => {
    @schema.BodyCodec::new(
      "text/plain",
      _ => raise @schema.DecodeFailure(kind=Malformed, message=name),
      (value : String) => @mttp_core.encode_utf8(value),
      @schema.string.schema(),
    )
  }
  let ep = @endpoint.endpoint
    .get("/")
    .output(@endpoint.json_out(failed("output"), status=400))
    .errors(@endpoint.json_out(failed("error"), status=400))
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      @mttp_core.Response::new(
        400,
        headers=@mttp_core.Headers::of([("content-type", "text/plain")]),
        body=Bytes(Bytes::make(1048577, b'x')),
      )
    }),
    @sim.FakeClock::new(),
  )
  defer client.close()
  @driver.run_sync(() => {
    for
      result in [
        ep.call(client, (), ()),
        ep.call_with(client, (), (), value => value),
      ] {
      guard result is Err(@client.Deserialization(head, message~, body~)) else {
        fail("expected deserialization after all candidates failed")
      }
      assert_eq(head.status, 400)
      assert_eq(message, "output")
      assert_eq(body.length(), 1048576)
    }
  })
}

///|
test "overlapping candidate buffering refuses one byte past the response limit" {
  let d = @driver.Driver::new()
  let feeds = []
  let ep = @endpoint.endpoint
    .get("/")
    .output(@endpoint.json_out(@schema.jint.body()).and_status())
    .errors(@endpoint.json_out(@schema.jstring.body(), status=400))
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      let feed = @sim.Feed::bytes(d, [b"\"den", b"ied\""])
      feeds.push(feed)
      @mttp_core.Response::new(
        400,
        headers=@mttp_core.Headers::of([("content-type", "application/json")]),
        body=Stream(@mttp_core.StreamBody::new(feed)),
      )
    }),
    @sim.FakeClock::new(),
    max_body_bytes=7,
  )
  defer client.close()
  d.run(() => {
    for scoped in [false, true] {
      try {
        ignore(
          if scoped {
            ep.call_with(client, (), (), value => value)
          } else {
            ep.call(client, (), ())
          },
        )
        fail("oversized response accepted")
      } catch {
        @mttp_core.TransportError(kind=TooLarge(limit~), ..) =>
          assert_eq(limit, 7)
        error => raise error
      }
    }
  })
  for feed in feeds {
    assert_eq(feed.reads(), 2)
    assert_eq(feed.closes(), 1)
  }
}

///|
test "query lists preserve named children nested definitions and schema problems" {
  let child : @schema.Schema = {
    name: Some("Child/Name"),
    json: { "allOf": [{ "$ref": "#/components/schemas/Nested" }] },
    defs: { "Nested": { "type": "string" } },
    problems: ["child definition problem"],
  }
  let codec = @schema.TextCodec::new(s => s, s => s, child)
  let ep = @endpoint.endpoint.get("/").input(@endpoint.query_list("q", codec))
  let schema = ep.doc().inputs[0].schema
  assert_eq(schema.name, None)
  assert_eq(schema.json, {
    "type": "array",
    "items": { "$ref": "#/components/schemas/Child~1Name" },
  })
  let defs : Map[String, Json] = Map([])
  let problems = []
  ignore(schema.reference(defs, problems~))
  assert_eq(defs.get("Child/Name"), Some(child.json))
  assert_eq(defs.get("Nested"), Some({ "type": "string" }))
  assert_eq(problems, ["child definition problem"])
  assert_true(
    @endpoint.check_definitions([ep.doc()])
    .iter()
    .any(p => p.fatal && p.message == "child definition problem"),
  )
}

///|
test "query list definitions expose named and reachable conflicts to the shared checker" {
  for named in [false, true] {
    let child : @schema.Schema = if named {
      @schema.Schema::of({ "type": "string" }).named("Shared")
    } else {
      {
        name: None,
        json: { "$ref": "#/components/schemas/Shared" },
        defs: { "Shared": { "type": "string" } },
        problems: [],
      }
    }
    let list = @endpoint.endpoint
      .get("/list")
      .input(
        @endpoint.query_list("q", @schema.TextCodec::new(s => s, s => s, child)),
      )
    let other = @endpoint.endpoint
      .get("/other")
      .input(
        @endpoint.query(
          "q",
          @schema.TextCodec::new(
            s => s,
            s => s,
            @schema.Schema::of({ "type": "integer" }).named("Shared"),
          ),
        ),
      )
    assert_true(
      @endpoint.check_definitions([list.doc(), other.doc()])
      .iter()
      .any(p => p.fatal && p.message == "conflicting schema definition Shared"),
    )
  }
}

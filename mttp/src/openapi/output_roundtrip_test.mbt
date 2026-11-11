///|
enum AuditReply {
  Number(Int32)
  Text(String)
  Empty
}

///|
test "output and declared-error unions describe every produced status and media" {
  let output = @endpoint.one_of([
    @endpoint.json_variant(200, @schema.jint.body()).contramap(
      value => if value is Number(n) { Some(n) } else { None },
      n => Number(n),
    ),
    @endpoint.json_variant(201, @schema.text_body).contramap(
      value => if value is Text(s) { Some(s) } else { None },
      s => Text(s),
    ),
    @endpoint.empty_variant(204).contramap(
      value => if value is Empty { Some(()) } else { None },
      _ => Empty,
    ),
  ])
  let ep = @endpoint.endpoint
    .get("/union")
    .input(@endpoint.query("mode", @schema.string))
    .output(output)
    .errors(@endpoint.text_out(status=409))
  let spec = project(ep.doc())
  let op = spec.paths["/union"].operations["get"]
  assert_eq(
    op.responses["200"].content["application/json"].schema,
    Some(@schema.jint.schema().json),
  )
  assert_eq(
    op.responses["201"].content["text/plain"].schema,
    Some(@schema.string.schema().json),
  )
  assert_eq(op.responses["204"].content.length(), 0)
  assert_true(op.responses["409"].content.contains("text/plain"))
  let server = ep.serve_public(mode => {
    match mode {
      "number" => Ok(Number(10))
      "text" => Ok(Text("hello"))
      "empty" => Ok(Empty)
      _ => Err("conflict")
    }
  })
  let router = @router.Router::new([server])
  let client = @client.Client::new(router, @sim.FakeClock::new())
  @driver.run_sync(() => {
    for mode in ["number", "text", "empty", "error"] {
      let reply = ep.request((), mode).send(client)
      assert_eq(
        @openapi.check_documented(spec, "/union", Get, reply.status),
        None,
      )
      match (mode, reply.body) {
        ("number", Ok(Ok(Number(10))))
        | ("text", Ok(Ok(Text("hello"))))
        | ("empty", Ok(Ok(Empty)))
        | ("error", Ok(Err("conflict"))) => ()
        _ => fail("union did not round trip")
      }
    }
  })
}

///|
test "dynamic output status and media describe the actual buffered and streamed response" {
  let ep = @endpoint.endpoint
    .get("/dynamic")
    .output(@endpoint.body_out().and_status())
  let value = (("application/custom", b"data"), 202)
  let response = dispatch(
    ep.serve_public(_ => Ok(value)),
    ep.request((), ()).raw(),
  )
  assert_eq(
    (response.status, response.headers.get("content-type"), response.body),
    (202, Some("application/custom"), @mttp.Body::Bytes(b"data")),
  )
  let op = project(ep.doc()).paths["/dynamic"].operations["get"]
  assert_true(op.responses["default"].content.contains("*/*"))
  let driver = @driver.Driver::new()
  let source = @sim.Feed::bytes(driver, [b"one", b"two"])
  let ep = @endpoint.endpoint
    .get("/stream-output")
    .output(@endpoint.stream_body_out())
  let response = dispatch(
    ep.serve_public(_ => {
      Ok(
        (Some("text/custom"), @mttp.Body::Stream(@mttp.StreamBody::new(source))),
      )
    }),
    ep.request((), ()).raw(),
  )
  assert_eq(source.reads(), 0)
  assert_true(
    project(ep.doc()).paths["/stream-output"].operations["get"].responses["200"].content.contains(
      "*/*",
    ),
  )
  assert_eq(
    @driver.run_sync(() => @client.read_body(response.body, 100)),
    b"onetwo",
  )
  assert_eq(source.closes(), 1)
}

///|
test "typed output headers and separate Set-Cookie fields match the projected headers" {
  let ep = @endpoint.endpoint
    .get("/headers")
    .output(
      @endpoint.text_out()
      .and_header("x-count", @schema.int)
      .set_cookie("sid")
      .set_cookie("theme"),
    )
  let value = ((("hello", 7), "token; Secure"), "dark")
  let response = dispatch(
    ep.serve_public(_ => Ok(value)),
    ep.request((), ()).raw(),
  )
  assert_eq(response.headers.get("x-count"), Some("7"))
  assert_eq(response.headers.get_all("set-cookie"), [
    "sid=token; Secure", "theme=dark",
  ])
  let headers = project(ep.doc()).paths["/headers"].operations["get"].responses["200"].headers
  assert_true(headers["x-count"].required)
  assert_eq(headers["x-count"].schema, Some(@schema.int.schema().json))
  assert_true(headers["set-cookie"].required)
  assert_eq(headers["set-cookie"].schema, Some(@schema.string.schema().json))
}

///|
test "SSE documents the framed string and each event in the OpenAPI 3.2 item shape" {
  let codec = @schema.object1(
    "AuditEvent",
    @schema.field("value", @schema.jint, (n : Int32) => n),
    n => n,
  )
  let ep = @endpoint.endpoint.get("/events").output(@endpoint.sse_out(codec))
  let spec = project(ep.doc())
  let router = @router.Router::new([
    ep.serve_public(_ => Ok(@endpoint.EventStream::from_array([1, 2]))),
  ])
  let client = @client.Client::new(router, @sim.FakeClock::new())
  let values : Array[Int32] = []
  @driver.run_sync(() => {
    let reply = ep
      .stream_request((), (), events => events.each(value => values.push(value)))
      .send(client)
    assert_eq(reply.status, 200)
    assert_eq(reply.headers.get("content-type"), Some("text/event-stream"))
    assert_true(reply.body is Ok(Ok(_)))
  })
  assert_eq(values, [1, 2])
  let media = spec.paths["/events"].operations["get"].responses["200"].content["text/event-stream"]
  assert_eq(media.schema, Some({ "type": "string" }))
  assert_eq(
    media.extensions.get("x-oai-itemSchema"),
    Some(sse_item_schema({ "$ref": "#/components/schemas/AuditEvent" })),
  )
  assert_true(spec.components.schemas.contains("AuditEvent"))
  assert_eq(@openapi.check_references(spec), [])
  let invalid = @schema.JsonCodec::new(
    json => json,
    json => json,
    @schema.Schema::of({ "$ref": "#/components/schemas/MissingEvent" }),
  )
  let bad = @endpoint.endpoint
    .get("/bad-events")
    .output(@endpoint.sse_out(invalid))
  try ignore(project(bad.doc())) catch {
    @endpoint.DefinitionError(problems) =>
      assert_true(
        problems
        .iter()
        .any(p => {
          p.message ==
          "unresolved schema reference #/components/schemas/MissingEvent"
        }),
      )
  } noraise {
    _ => fail("SSE payload reference was not checked")
  }
}

///|
/// The item schema OpenAPI 3.2 gives a text/event-stream event, with the
/// JSON payload described as the content of the data string.
fn sse_item_schema(payload : Json) -> Json {
  {
    "type": "object",
    "required": ["data"],
    "properties": {
      "event": { "type": "string" },
      "data": {
        "type": "string",
        "contentMediaType": "application/json",
        "contentSchema": payload,
      },
      "id": { "type": "string" },
      "retry": { "type": "integer", "minimum": 0 },
    },
  }
}

///|
test "a dynamic media representation leaves SSE items unconstrained" {
  let ep = @endpoint.endpoint
    .get("/mixed")
    .output(@endpoint.sse_out(@schema.jint))
    .errors(@endpoint.body_out().and_status())
  let content = project(ep.doc()).paths["/mixed"].operations["get"].responses["200"].content
  // body_out can also send text/event-stream, with items of any shape.
  assert_eq(
    content["text/event-stream"].extensions.get("x-oai-itemSchema"),
    None,
  )
  assert_eq(
    content["text/event-stream"].schema,
    Some({ "anyOf": [{ "type": "string" }, @schema.raw_bytes.schema().json] }),
  )
}

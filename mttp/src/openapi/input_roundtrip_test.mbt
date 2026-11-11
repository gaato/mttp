///|
test "path scalar and rest inputs round trip with projected serialization" {
  let ep = @endpoint.endpoint
    .get("/items/{id}")
    .input(@endpoint.path("id", @schema.int))
    .output(@endpoint.text_out())
  let spec = project(ep.doc())
  let p = spec.paths["/items/{id}"].operations["get"].parameters[0]
  assert_eq((p.in_, p.name, p.required), ("path", "id", true))
  assert_eq(p.schema, Some(@schema.int.schema().json))
  let response = dispatch(
    ep.serve_public(id => Ok(id.to_string())),
    ep.request((), 7).raw(),
  )
  assert_eq(response.body, @mttp.Body::Bytes(b"7"))
  assert_eq(
    dispatch(ep.serve_public(_ => Ok("")), @mttp.Request::get("/items/bad")).status,
    400,
  )
  let rest = @endpoint.endpoint
    .get("/files/{tail...}")
    .input(@endpoint.paths("tail"))
    .output(@endpoint.json_out(@schema.array(@schema.jstring).body()))
  let value = ["a/b", "", "x y"]
  let response = dispatch(
    rest.serve_public(parts => Ok(parts)),
    rest.request((), value).raw(),
  )
  assert_eq(
    @schema.array(@schema.jstring)
    .body()
    .decode(response.body.as_bytes().unwrap()),
    value,
  )
  let p = project(rest.doc()).paths["/files/{tail}"].operations["get"].parameters[0]
  assert_true(p.required)
  assert_eq(p.extensions["x-mttp-rest"], Json(true))
  assert_eq(p.schema, Some({ "type": "array", "items": { "type": "string" } }))
}

///|
test "scalar query inputs round trip with requiredness and validation schema" {
  let input = @endpoint.pair(
    @endpoint.query("n", @schema.int.validate(@schema.minimum(1))),
    @endpoint.query("label", @schema.string).optional(),
  )
  let ep = @endpoint.endpoint
    .get("/query")
    .input(input)
    .output(@endpoint.text_out())
  let op = project(ep.doc()).paths["/query"].operations["get"]
  assert_eq(op.parameters.map(p => (p.name, p.in_, p.required)), [
    ("n", "query", true),
    ("label", "query", false),
  ])
  assert_eq(
    op.parameters[0].schema,
    Some(@schema.int.validate(@schema.minimum(1)).schema().json),
  )
  let server = ep.serve_public(value => {
    assert_eq(value, (2, Some("a b")))
    Ok("ok")
  })
  assert_eq(
    dispatch(server, ep.request((), (2, Some("a b"))).raw()).status,
    200,
  )
  for url in ["/query", "/query?n=0", "/query?n=1&n=2"] {
    assert_eq(dispatch(server, @mttp.Request::get(url)).status, 400)
  }
  let server = ep.serve_public(value => {
    assert_eq(value, (2, None))
    Ok("ok")
  })
  assert_eq(dispatch(server, ep.request((), (2, None)).raw()).status, 200)
}

///|
test "query lists round trip as optional form-exploded arrays including absence" {
  let ep = @endpoint.endpoint
    .get("/list")
    .input(@endpoint.query_list("q", @schema.int))
    .output(@endpoint.json_out(@schema.array(@schema.jint).body()))
  let op = project(ep.doc()).paths["/list"].operations["get"]
  let p = op.parameters[0]
  assert_eq(
    (p.in_, p.required, p.style.unwrap_or("form"), p.explode.unwrap_or(true)),
    ("query", false, "form", true),
  )
  assert_eq(
    p.schema,
    Some({ "type": "array", "items": @schema.int.schema().json }),
  )
  for values in [[], [1, 2, 1]] {
    let response = dispatch(
      ep.serve_public(values => Ok(values)),
      ep.request((), values).raw(),
    )
    assert_eq(
      @schema.array(@schema.jint)
      .body()
      .decode(response.body.as_bytes().unwrap()),
      values,
    )
  }
}

///|
test "header and cookie inputs round trip with documented names types and optionality" {
  let ep = @endpoint.endpoint
    .post("/heads")
    .input(
      @endpoint.Input::map3(
        @endpoint.header("X-Count", @schema.int),
        @endpoint.cookie("sid", @schema.string),
        @endpoint.last_event_id(),
        (a, b, c) => (a, b, c),
        value => value,
      ),
    )
    .output(@endpoint.text_out())
  let op = project(ep.doc()).paths["/heads"].operations["post"]
  assert_eq(op.parameters.map(p => (p.name, p.in_, p.required)), [
    ("X-Count", "header", true),
    ("sid", "cookie", true),
    ("last-event-id", "header", false),
  ])
  assert_eq(op.parameters[0].schema, Some(@schema.int.schema().json))
  let server = ep.serve_public(value => {
    assert_eq(value, (7, "token", Some("event-1")))
    Ok("ok")
  })
  assert_eq(
    dispatch(server, ep.request((), (7, "token", Some("event-1"))).raw()).status,
    200,
  )
  assert_eq(dispatch(server, @mttp.Request::post("/heads")).status, 400)
}

///|
test "unbounded header and query collections add no invented named requirements" {
  let ep = @endpoint.endpoint
    .post("/collections")
    .input(@endpoint.pair(@endpoint.headers(), @endpoint.query_params()))
    .output(@endpoint.text_out())
  let op = project(ep.doc()).paths["/collections"].operations["post"]
  assert_eq(op.parameters.length(), 0)
  assert_eq(op.request_body, None)
  let hs = @mttp.Headers::of([("x-any", "one"), ("x-any", "two")])
  let qs = [("q", "a"), ("q", "b")]
  let response = dispatch(
    ep.serve_public(value => {
      assert_eq(value, (hs, qs))
      Ok("ok")
    }),
    ep.request((), (hs, qs)).raw(),
  )
  assert_eq(response.status, 200)
}

///|
fn[T : Eq + @debug.Debug] body_roundtrip(
  codec : @schema.BodyCodec[T],
  value : T,
) -> @apispec.Operation raise {
  let ep = @endpoint.endpoint
    .post("/body")
    .input(@endpoint.body(codec))
    .output(@endpoint.json_out(codec))
  let response = dispatch(
    ep.serve_public(input => {
      assert_eq(input, value)
      Ok(input)
    }),
    ep.request((), value).raw(),
  )
  assert_eq(response.status, 200)
  assert_eq(codec.decode(response.body.as_bytes().unwrap()), value)
  let op = project(ep.doc()).paths["/body"].operations["post"]
  assert_true(op.request_body.unwrap().required)
  assert_eq(
    op.request_body.unwrap().content[codec.media_type()].schema,
    Some(codec.schema().json),
  )
  assert_eq(
    op.responses["200"].content[codec.media_type()].schema,
    Some(codec.schema().json),
  )
  assert_eq(
    dispatch(ep.serve_public(input => Ok(input)), @mttp.Request::post("/body")).status,
    400,
  )
  assert_eq(
    dispatch(
      ep.serve_public(input => Ok(input)),
      ep.request((), value).raw().set_header("content-type", "wrong/type"),
    ).status,
    415,
  )
  op
}

///|
test "JSON text and opaque byte body codecs round trip with projected representations" {
  ignore(body_roundtrip(@schema.jint.body(), 10))
  ignore(body_roundtrip(@schema.text_body, "hello é"))
  ignore(body_roundtrip(@schema.raw_bytes, b"\xff\x00"))
}

///|
test "typed JSON body validation agrees with the projected constraints" {
  let codec = @schema.jint.validate(@schema.minimum(10))
  let ep = @endpoint.endpoint
    .post("/validated")
    .input(@endpoint.body(codec.body()))
    .output(@endpoint.json_out(codec.body()))
  let op = project(ep.doc()).paths["/validated"].operations["post"]
  assert_eq(
    op.request_body.unwrap().content["application/json"].schema,
    Some(codec.schema().json),
  )
  let server = ep.serve_public(value => Ok(value))
  assert_eq(
    dispatch(server, ep.request((), 10).raw()).body,
    @mttp.Body::Bytes(b"10"),
  )
  for json in [Json(9), Json("not an integer")] {
    assert_eq(
      dispatch(server, @mttp.Request::post("/validated").body_json(json)).status,
      400,
    )
  }
}

///|
test "form bodies describe repeated names as well as scalar fields" {
  let op = body_roundtrip(@schema.form_body(), [
    ("q", "one"),
    ("q", "two"),
    ("label", "a b"),
  ])
  assert_eq(
    op.request_body.unwrap().content["application/x-www-form-urlencoded"].schema,
    Some({
      "type": "object",
      "additionalProperties": {
        "anyOf": [
          { "type": "string" },
          { "type": "array", "items": { "type": "string" } },
        ],
      },
    }),
  )
}

///|
test "optional typed bodies describe absence and present empty bytes accurately" {
  let ep = @endpoint.endpoint
    .post("/optional-text")
    .input(@endpoint.body(@schema.text_body).optional())
    .output(@endpoint.text_out())
  let body = project(ep.doc()).paths["/optional-text"].operations["post"].request_body.unwrap()
  assert_false(body.required)
  assert_true(body.content.contains("text/plain"))
  let server = ep.serve_public(input => {
    Ok(
      match input {
        None => "absent"
        Some(text) => "present:" + text
      },
    )
  })
  assert_eq(
    dispatch(server, ep.request((), None).raw()).body,
    @mttp.Body::Bytes(b"absent"),
  )
  assert_eq(
    dispatch(server, ep.request((), Some("")).raw()).body,
    @mttp.Body::Bytes(b"present:"),
  )
}

///|
test "stream and opaque multipart bodies round trip without pretending to parse parts" {
  let driver = @driver.Driver::new()
  let (media, bytes) = @multipart.encode(
    [@multipart.Part::text("field", "value")],
    "B",
  )
  for
    (kind, wire, body) in [
      ("application/octet-stream", "application/octet-stream", b"\xff\x00"),
      ("multipart/form-data", media, bytes),
    ] {
    let ep = @endpoint.endpoint
      .post("/stream")
      .input(@endpoint.stream_body(media_type=kind))
      .output(@endpoint.bytes_out())
    let source = @sim.Feed::bytes(driver, [body])
    let request = ep.request((), source).raw().set_header("content-type", wire)
    let response = dispatch(
      ep.serve_public(reader => Ok(@mttp.read_bounded(reader, 4096))),
      request,
    )
    assert_eq(response.status, 200)
    assert_eq(response.body, @mttp.Body::Bytes(body))
    assert_eq(source.closes(), 1)
    let op = project(ep.doc()).paths["/stream"].operations["post"]
    assert_true(op.request_body.unwrap().required)
    assert_eq(
      op.request_body.unwrap().content[kind].schema,
      Some({ "type": "string" }),
    )
    assert_true(op.responses.contains("413"))
    assert_true(op.responses.contains("415"))
  }
}

///|
test "derived inputs are server metadata and impose no wire requirements" {
  let ep = @endpoint.endpoint
    .get("/derived")
    .input(
      @endpoint.pair(
        @endpoint.attribute(@mttp.remote_addr),
        @endpoint.client_ip(),
      ),
    )
    .output(@endpoint.text_out())
  let op = project(ep.doc()).paths["/derived"].operations["get"]
  assert_eq(op.parameters.length(), 0)
  assert_eq(op.request_body, None)
  let request = ep
    .request((), (None, None))
    .raw()
    .attribute(@mttp.remote_addr, "adapter")
  assert_eq(
    dispatch(
      ep.serve_public(value => {
        assert_eq(value, (Some("adapter"), Some("adapter")))
        Ok("ok")
      }),
      request,
    ).status,
    200,
  )
  let derived = @endpoint.Input::new(
    [@endpoint.Atom::new(Derived, "computed", @schema.Schema::of({}))],
    _ => @endpoint.Staged::ready(7),
    (_, _) => (),
  )
  let ep = @endpoint.endpoint.get("/derived-atom").input(derived)
  let op = project(ep.doc()).paths["/derived-atom"].operations["get"]
  assert_eq(op.parameters.length(), 0)
  assert_eq(op.request_body, None)
  assert_eq(
    dispatch(
      ep.serve_public(value => {
        assert_eq(value, 7)
        Ok(())
      }),
      ep.request((), 7).raw(),
    ).status,
    200,
  )
}

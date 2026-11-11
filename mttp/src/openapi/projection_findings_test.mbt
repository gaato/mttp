///|
fn project(
  doc : @endpoint.EndpointDoc,
) -> @apispec.OpenApi raise @endpoint.DefinitionError {
  @openapi.to_openapi([doc], @apispec.Info::new("Audit", "1"))
}

///|
test "dot-only literal segments are refused instead of documenting a route normalized away by transports" {
  for literal in [".", ".."] {
    let ep = @endpoint.endpoint.get("/files/" + literal + "/item")
    try ignore(project(ep.doc())) catch {
      @endpoint.DefinitionError(problems) =>
        assert_true(
          problems
          .iter()
          .any(p => p.fatal && p.message == "dot-only literal path segment"),
        )
    } noraise {
      _ => fail("unsafe literal route projected")
    }
    try ignore(ep.request((), ())) catch {
      @client.InvalidRequest(_) => ()
    } noraise {
      _ => fail("unsafe literal route encoded")
    }
  }
}

///|
fn dispatch(
  server : @endpoint.ServerEndpoint,
  request : @mttp.Request,
) -> @mttp.Response raise {
  let router = @router.Router::new([server])
  @driver.run_sync(() => router.dispatch(request))
}

///|
test "projection encodes literal path segments exactly as the endpoint client" {
  for literal in ["a%2Fb", "a b", "café", "x:y", "%7Bname%7D"] {
    let template = "/files/" + literal + "/{id}"
    let ep = @endpoint.endpoint
      .get(template)
      .input(@endpoint.path("id", @schema.string))
      .output(@endpoint.text_out())
    let request = ep.request((), "x/y").raw()
    let response = dispatch(ep.serve_public(id => Ok(id)), request)
    assert_eq(response.status, 200)
    assert_eq(response.body, @mttp.Body::Bytes(b"x/y"))
    let expected = "/files/" + @mttp.percent_encode(literal) + "/{id}"
    let spec = project(ep.doc())
    assert_true(spec.paths.contains(expected))
    assert_eq(@openapi.check_documented(spec, template, Get, 200), None)
  }
}

///|
test "raw-only body projection declares wildcard content with atom requiredness" {
  let ep = @endpoint.endpoint
    .post("/raw")
    .input(@endpoint.raw_body())
    .output(@endpoint.bytes_out())
  let response = dispatch(
    ep.serve_public(bytes => Ok(bytes)),
    ep
    .request((), b"\xff\x00")
    .raw()
    .header("content-type", "application/custom"),
  )
  assert_eq(response.status, 200)
  assert_eq(response.body, @mttp.Body::Bytes(b"\xff\x00"))
  let spec = project(ep.doc())
  guard spec.paths["/raw"].operations["post"].request_body is Some(body) else {
    fail("raw body missing from projection")
  }
  assert_true(body.required)
  assert_eq(body.content.length(), 1)
  assert_true(body.content.contains("*/*"))
  let optional = @endpoint.endpoint
    .post("/optional")
    .input(@endpoint.raw_body().optional())
  assert_false(
    project(optional.doc()).paths["/optional"].operations["post"].request_body.unwrap().required,
  )
}

///|
test "required and optional raw bodies distinguish absence from present empty bytes" {
  let ep = @endpoint.endpoint.post("/raw").input(@endpoint.raw_body())
  assert_eq(
    dispatch(ep.serve_public(_ => Ok(())), @mttp.Request::post("/raw")).status,
    400,
  )
  assert_eq(
    dispatch(
      ep.serve_public(_ => Ok(())),
      @mttp.Request::post("/raw").body_bytes(b""),
    ).status,
    200,
  )
  let optional = @endpoint.endpoint
    .post("/optional")
    .input(@endpoint.raw_body().optional())
    .output(@endpoint.text_out())
  let server = optional.serve_public(bytes => {
    Ok(if bytes is None { "absent" } else { "present" })
  })
  assert_eq(
    dispatch(server, optional.request((), None).raw()).body,
    @mttp.Body::Bytes(b"absent"),
  )
  assert_eq(
    dispatch(server, optional.request((), Some(b"")).raw()).body,
    @mttp.Body::Bytes(b"present"),
  )
}

///|
test "raw security keeps typed body media and contributes requiredness" {
  let ep = @endpoint.endpoint
    .post("/signed")
    .security(@endpoint.raw_body())
    .input(@endpoint.body(@schema.jint.body()).optional())
    .output(@endpoint.text_out())
  let response = dispatch(
    ep.serve(bytes => Ok(bytes), (bytes, value) => {
      assert_eq(bytes, b"10")
      assert_eq(value, Some(10))
      Ok("ok")
    }),
    ep.request(b"10", Some(10)).raw(),
  )
  assert_eq(response.status, 200)
  let body = project(ep.doc()).paths["/signed"].operations["post"].request_body.unwrap()
  assert_true(body.required)
  assert_eq(body.content.length(), 1)
  assert_true(body.content.contains("application/json"))
  assert_false(body.content.contains("*/*"))
}

///|
test "projected media keys match case-insensitive parameter-tolerant body decoding" {
  let codec = @schema.BodyCodec::new(
    "Text/Plain; charset=utf-8",
    bytes => @schema.text_body.decode(bytes),
    text => @schema.text_body.encode(text),
    @schema.string.schema(),
  )
  let ep = @endpoint.endpoint
    .post("/text")
    .input(@endpoint.body(codec))
    .output(@endpoint.json_out(codec))
  let response = dispatch(ep.serve_public(text => Ok(text)), {
    ..ep.request((), "hello").raw(),
    headers: @mttp.Headers::of([("content-type", "text/plain; other=value")]),
  })
  assert_eq(response.status, 200)
  assert_eq(response.body, @mttp.Body::Bytes(b"hello"))
  let operation = project(ep.doc()).paths["/text"].operations["post"]
  assert_true(operation.request_body.unwrap().content.contains("text/plain"))
  assert_true(operation.responses["200"].content.contains("text/plain"))
}

///|
test "fixed output headers project their actual constant value" {
  let ep = @endpoint.endpoint
    .get("/fixed")
    .output(
      @endpoint.one_of([
        @endpoint.empty_variant(200).fixed_header("x-mode", "fixed"),
      ]),
    )
  let response = dispatch(
    ep.serve_public(_ => Ok(())),
    ep.request((), ()).raw(),
  )
  assert_eq(response.headers.get("x-mode"), Some("fixed"))
  assert_eq(
    project(ep.doc()).paths["/fixed"].operations["get"].responses["200"].headers["x-mode"].schema,
    Some({ "type": "string", "const": "fixed" }),
  )
}

///|
test "an omittable field is optional and not nullable in OpenAPI" {
  let link : @schema.JsonCodec[(String, String?)] = @schema.object2(
    "Link",
    @schema.field("title", @schema.jstring, v => v.0),
    @schema.field("url", @schema.omittable(@schema.jstring), v => v.1),
    (title, url) => (title, url),
  )
  let ep = @endpoint.endpoint
    .post("/links")
    .input(@endpoint.body(link.body()))
    .output(@endpoint.no_content())
  assert_eq(
    project(ep.doc()).components.schemas.get("Link"),
    Some({
      "type": "object",
      "properties": {
        "title": { "type": "string" },
        "url": { "type": "string" },
      },
      "required": ["title"],
    }),
  )
}

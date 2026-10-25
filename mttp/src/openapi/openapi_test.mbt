///|
test "OpenAPI merges declared and framework responses with typed headers and AND security" {
  let ep = @endpoint.endpoint
    .get("/items/{id}")
    .security(
      @endpoint.pair(
        @endpoint.bearer(),
        @endpoint.api_key_query("key", scheme_name="queryKey"),
      ),
    )
    .input(@endpoint.path("id", @schema.int))
    .output(
      @endpoint.json_out(@schema.jstring.body(), status=404).and_header(
        "X-Count", @schema.int,
      ),
    )
    .operation_id("item")
    .summary("Read item")
    .description("A description")
    .tag("items")
    .deprecated()
  let spec = @openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1"), servers=[
    @apispec.Server::new("https://example.test"),
  ])
  let operation = spec.paths["/items/{id}"].operations["get"]
  assert_eq(operation.security, [{ "bearer": [], "queryKey": [] }])
  assert_eq(spec.components.security_schemes["queryKey"].in_, Some("query"))
  assert_eq(operation.responses["404"].content.length(), 2)
  assert_eq(operation.responses["404"].headers["x-count"].schema, {
    "type": "integer",
    "format": "int32",
  })
  assert_eq(operation.parameters[0].name, "id")
  assert_eq(operation.tags, ["items"])
  assert_true(operation.deprecated)
  assert_eq(@openapi.check_references(spec), [])
  let decoded : @apispec.OpenApi = @json.from_json(Json(spec))
  assert_eq(decoded, spec)
  assert_eq(@openapi.check_documented(spec, "/items/{id}", Head, 404), None)
  assert_true(
    @openapi.check_documented(spec, "/items/{id}", Get, 299) is Some(_),
  )
  assert_true(
    @openapi.check_documented(spec, "/items/{id}", Post, 200) is Some(_),
  )
  assert_true(@openapi.check_documented(spec, "/absent", Get, 200) is Some(_))
}

///|
test "OpenAPI omits null optionals and retains flattened extensions" {
  let info = @apispec.Info::new("Test", "1", extensions={
    "x-team": "test",
    "title": "ignored",
  })
  assert_eq(Json(info), { "title": "Test", "version": "1", "x-team": "test" })
  let decoded : @apispec.Info = @json.from_json(Json(info))
  assert_eq(decoded.extensions, { "x-team": "test" })
  let ep = @endpoint.endpoint
    .post("/upload")
    .input(@endpoint.body(@schema.text_body))
    .output(@endpoint.body_out().and_status())
  let spec = @openapi.to_openapi([ep.doc()], info)
  let operation = spec.paths["/upload"].operations["post"]
  assert_true(operation.responses.contains("default"))
  assert_true(operation.responses["default"].content.contains("*/*"))
  assert_true(operation.responses.contains("413"))
  assert_true(operation.responses.contains("415"))
  assert_eq(@openapi.check_documented(spec, "/upload", Post, 202), None)
  assert_true(operation.request_body.unwrap().content.contains("text/plain"))
}

///|
test "schema collisions and dangling references are rejected" {
  let codec = @schema.BodyCodec::new(
    "application/json",
    bytes => bytes,
    bytes => bytes,
    @schema.Schema::of({ "$ref": "#/components/schemas/Missing" }),
  )
  let endpoint = @endpoint.endpoint
    .get("/bad")
    .output(@endpoint.json_out(codec))
  let failed = try {
    ignore(
      @openapi.to_openapi([endpoint.doc()], @apispec.Info::new("Test", "1")),
    )
    false
  } catch {
    @endpoint.DefinitionError(_) => true
  }
  assert_true(failed)
  let first = @schema.BodyCodec::new(
    "one/type",
    bytes => bytes,
    bytes => bytes,
    @schema.Schema::of({ "type": "string" }).named("Same"),
  )
  let second = @schema.BodyCodec::new(
    "two/type",
    bytes => bytes,
    bytes => bytes,
    @schema.Schema::of({ "type": "integer" }).named("Same"),
  )
  let a = @endpoint.endpoint.get("/one").output(@endpoint.json_out(first))
  let b = @endpoint.endpoint.get("/two").output(@endpoint.json_out(second))
  assert_true(
    @endpoint.check_definitions([a.doc(), b.doc()]).iter().any(p => p.fatal),
  )
}

///|
test "schema reference walker treats examples as data and checks escaped pointers" {
  let spec = @apispec.OpenApi::new(
    @apispec.Info::new("Test", "1"),
    {},
    components=@apispec.Components::new(schemas={
      "Root": {
        "properties": { "x": { "$ref": "#/components/schemas/A~1B~0C" } },
        "examples": [{ "$ref": "not a schema" }],
        "const": { "$ref": "also data" },
      },
      "A/B~C": { "type": "string" },
    }),
  )
  assert_eq(@openapi.check_references(spec), [])
  for
    reference in [
      "#/missing", "#/components/schemas/A~2B", "external.json", "#/components/schemas/A~",
      "#/info/title/child",
    ] {
    spec.components.schemas["Bad"] = { "$ref": Json(reference) }
    assert_eq(@openapi.check_references(spec).length(), 1)
  }
}

///|
test "documentation endpoint returns the serialized OpenAPI document" {
  let spec = @openapi.to_openapi(
    [@endpoint.endpoint.get("/ok").doc()],
    @apispec.Info::new("Test", "1"),
  )
  let endpoint = @openapi.docs_endpoint(spec)
  @driver.run_sync(() => {
    let response = endpoint.dispatch(
      @model.Request::get("/openapi.json"),
      Map([]),
      @endpoint.DispatchContext::new(),
    )
    assert_eq(response.status, 200)
    assert_eq(response.headers.get("content-type"), Some("application/json"))
    assert_eq(
      response.body,
      @model.Bytes(@model.encode_utf8(Json(spec).stringify())),
    )
  })
}

///|
test "reference pointers handle array indices percent escapes and traversal limits" {
  let spec = @apispec.OpenApi::new(
    @apispec.Info::new("Test", "1"),
    {},
    components=@apispec.Components::new(schemas={
      "Choice": { "oneOf": [{ "type": "string" }] },
    }),
  )
  for
    reference in [
      "#", "#%2Fcomponents/schemas/Choice", "#/components/schemas/Choice/oneOf/0",
    ] {
    spec.components.schemas["Ref"] = { "$ref": Json(reference) }
    assert_eq(@openapi.check_references(spec), [])
  }
  for
    reference in [
      "#anchor", "#/components/schemas/%GG", "#/components/schemas/Choice/oneOf/",
      "#/components/schemas/Choice/oneOf/00", "#/components/schemas/Choice/oneOf/x",
      "#/components/schemas/Choice/oneOf/9", "#/components/schemas/Choice/oneOf/999999999999999999999",
    ] {
    spec.components.schemas["Ref"] = { "$ref": Json(reference) }
    assert_eq(@openapi.check_references(spec).length(), 1)
  }
  spec.components.schemas.remove("Ref")
  let mut nested : Json = Json::empty_object()
  for _ in 0..<128 {
    nested = { "not": nested }
  }
  spec.components.schemas["Nested"] = nested
  assert_eq(@openapi.check_references(spec), [])
  spec.components.schemas["Nested"] = { "not": nested }
  assert_true(!@openapi.check_references(spec).is_empty())
}

///|
test "optional security signatures and metadata parameters project without invented schemes" {
  let security = @endpoint.pair(
    @endpoint.basic().optional(),
    @endpoint.api_key_cookie("key", scheme_name="cookieKey").optional(),
  )
  let ep = @endpoint.endpoint
    .post("/")
    .security(security)
    .input(
      @endpoint.Input::map3(
        @endpoint.query("q", @schema.string),
        @endpoint.header("x", @schema.int),
        @endpoint.cookie("c", @schema.string),
        (a, b, c) => (a, b, c),
        value => value,
      ),
    )
  let signed = @endpoint.endpoint
    .post("/signed")
    .security(
      @endpoint.pair(
        @endpoint.signature_header("signature"),
        @endpoint.raw_body(),
      ),
    )
  let key = @endpoint.endpoint
    .get("/key")
    .security(@endpoint.api_key_header("key", scheme_name="headerKey"))
  let spec = @openapi.to_openapi(
    [ep.doc(), signed.doc(), key.doc()],
    @apispec.Info::new("Test", "1"),
  )
  assert_eq(spec.paths["/"].operations["post"].security.length(), 2)
  assert_eq(spec.paths["/"].operations["post"].parameters.map(p => p.in_), [
    "query", "header", "cookie",
  ])
  assert_eq(
    spec.paths["/signed"].operations["post"].parameters[0].name,
    "signature",
  )
  assert_eq(spec.components.security_schemes.length(), 3)
  let collision = @endpoint.endpoint
    .get("/collision")
    .security(@endpoint.api_key_header("different", scheme_name="headerKey"))
  let rejected = try {
    ignore(
      @openapi.to_openapi(
        [key.doc(), collision.doc()],
        @apispec.Info::new("Test", "1"),
      ),
    )
    false
  } catch {
    @endpoint.DefinitionError(_) => true
  }
  assert_true(rejected)
  let invalid = try {
    ignore(
      @openapi.to_openapi(
        [@endpoint.endpoint.doc()],
        @apispec.Info::new("Test", "1"),
      ),
    )
    false
  } catch {
    @endpoint.DefinitionError(_) => true
  }
  assert_true(invalid)
  let unsupported = try {
    ignore(
      @openapi.to_openapi(
        [@endpoint.endpoint.with_method(Connect, "/").doc()],
        @apispec.Info::new("Test", "1"),
      ),
    )
    false
  } catch {
    @endpoint.DefinitionError(_) => true
  }
  assert_true(unsupported)
}

///|
test "rest routes retain observed status checks and refuse projected collisions" {
  let rest = @endpoint.endpoint
    .get("/files/{tail...}")
    .input(@endpoint.paths("tail"))
  let spec = @openapi.to_openapi([rest.doc()], @apispec.Info::new("Test", "1"))
  assert_eq(@openapi.check_documented(spec, "/files/{tail...}", Get, 200), None)
  assert_eq(
    spec.paths["/files/{tail}"].operations["get"].parameters[0].extensions["x-mttp-rest"],
    Json::boolean(true),
  )
  let single = @endpoint.endpoint
    .get("/files/{tail}")
    .input(@endpoint.path("tail", @schema.string))
  let refused = try {
    ignore(
      @openapi.to_openapi(
        [rest.doc(), single.doc()],
        @apispec.Info::new("Test", "1"),
      ),
    )
    false
  } catch {
    @endpoint.DefinitionError(_) => true
  }
  assert_true(refused)
}

///|
test "multiple representations merge with oneOf and framework Problem cannot be overwritten" {
  let output = @endpoint.one_of([
    @endpoint.json_variant(200, @schema.jint.body()).and_header(
      "x", @schema.int,
    ),
    @endpoint.json_variant(200, @schema.jint.body()).and_header(
      "x", @schema.int,
    ),
    @endpoint.json_variant(
      200,
      @schema.jint.validate(@schema.minimum(10)).body(),
    ).and_header("x", @schema.int.validate(@schema.minimum(10))),
  ])
  let ep = @endpoint.endpoint.get("/").output(output)
  let spec = @openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1"))
  assert_true(
    spec.paths["/"].operations["get"].responses["200"].content["application/json"].schema
    is { "oneOf": Array(_), .. },
  )
  assert_true(
    spec.paths["/"].operations["get"].responses["200"].headers["x"].schema
    is { "oneOf": Array(_), .. },
  )
  let codec = @schema.BodyCodec::new(
    "text/plain",
    _ => (),
    _ => b"",
    @schema.Schema::of({ "type": "string" }).named("Problem"),
  )
  let endpoint = @endpoint.endpoint.get("/").output(@endpoint.json_out(codec))
  let rejected = try {
    ignore(
      @openapi.to_openapi([endpoint.doc()], @apispec.Info::new("Test", "1")),
    )
    false
  } catch {
    @endpoint.DefinitionError(_) => true
  }
  assert_true(rejected)
}

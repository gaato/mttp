///|
test "overlapping body schemas project as inclusive unions" {
  let narrow = @schema.jint.validate(@schema.minimum(10))
  // Both codecs admit 10: an exclusive oneOf would reject a real response.
  assert_eq(@schema.jint.from_json(10), 10)
  assert_eq(narrow.from_json(10), 10)
  let output = @endpoint.one_of([
    @endpoint.json_variant(200, @schema.jint.body()).and_header(
      "x", @schema.int,
    ),
    @endpoint.json_variant(200, narrow.body()).and_header(
      "x",
      @schema.int.validate(@schema.minimum(10)),
    ),
  ])
  let ep = @endpoint.endpoint.get("/").output(output)
  let spec = @openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1"))
  let response = spec.paths["/"].operations["get"].responses["200"]
  assert_eq(
    response.content["application/json"].schema,
    Some({ "anyOf": [@schema.jint.schema().json, narrow.schema().json] }),
  )
}

///|
test "overlapping header schemas project as inclusive unions" {
  let narrow = @schema.int.validate(@schema.minimum(10))
  assert_eq(@schema.int.decode("10"), 10)
  assert_eq(narrow.decode("10"), 10)
  let output = @endpoint.one_of([
    @endpoint.empty_variant(200).and_header("x", @schema.int),
    @endpoint.empty_variant(200).and_header("x", narrow),
  ])
  let ep = @endpoint.endpoint.get("/").output(output)
  let spec = @openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1"))
  let header = spec.paths["/"].operations["get"].responses["200"].headers["x"]
  assert_eq(
    header.schema,
    Some({ "anyOf": [@schema.int.schema().json, narrow.schema().json] }),
  )
  assert_true(header.required)
}

///|
test "merged headers are required only when every declared representation supplies them" {
  let present = @endpoint.empty_variant(200).fixed_header("X-Only", "value")
  let absent = @endpoint.empty_variant(200)
  for
    variants in [
      [present, absent],
      [absent, present],
      [present, absent, present],
      [absent, present, present],
    ] {
    let ep = @endpoint.endpoint.get("/").output(@endpoint.one_of(variants))
    let spec = @openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1"))
    assert_false(
      spec.paths["/"].operations["get"].responses["200"].headers["x-only"].required,
    )
  }
  let ep = @endpoint.endpoint
    .get("/")
    .output(@endpoint.one_of([present, present]))
  let spec = @openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1"))
  assert_true(
    spec.paths["/"].operations["get"].responses["200"].headers["x-only"].required,
  )
}

///|
test "framework problem representations make declared headers optional" {
  let ep = @endpoint.endpoint
    .get("/")
    .output(
      @endpoint.json_out(@schema.jint.body(), status=404).and_header(
        "Location", @schema.string,
      ),
    )
  let spec = @openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1"))
  let response = spec.paths["/"].operations["get"].responses["404"]
  assert_true(response.content.contains("application/json"))
  assert_true(response.content.contains("application/problem+json"))
  assert_false(response.headers["location"].required)
}

///|
test "headers omitted by another media type are optional without weakening shared headers" {
  let other = @schema.BodyCodec::new(
    "application/custom",
    _ => 1,
    _ => b"1",
    @schema.jint.schema(),
  )
  for reverse in [false, true] {
    let with_extra = @endpoint.json_variant(200, @schema.jint.body())
      .fixed_header("x-shared", "a")
      .fixed_header("x-extra", "b")
    let shared = @endpoint.json_variant(200, other).fixed_header(
      "X-Shared", "c",
    )
    let variants = if reverse {
      [shared, with_extra]
    } else {
      [with_extra, shared]
    }
    let ep = @endpoint.endpoint.get("/").output(@endpoint.one_of(variants))
    let spec = @openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1"))
    let headers = spec.paths["/"].operations["get"].responses["200"].headers
    assert_true(headers["x-shared"].required)
    assert_false(headers["x-extra"].required)
  }
}

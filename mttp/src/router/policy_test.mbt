///|
test "default rejection policy distinguishes body limits media types and authentication" {
  let doc = @endpoint.endpoint.post("/").doc()
  for
    (location, expected) in [
      (@endpoint.Path, 400),
      (@endpoint.Query, 400),
      (@endpoint.Header, 400),
      (@endpoint.Cookie, 400),
      (@endpoint.Derived, 400),
      (@endpoint.Auth(scheme=Basic, scheme_name="basic"), 401),
      (@endpoint.Auth(scheme=ApiKeyHeader("key"), scheme_name="key"), 401),
    ] {
    let atom = @endpoint.Atom::new(location, "field", @schema.string.schema())
    let failure = @endpoint.InputFailure::new(
      atom,
      @schema.DecodeFailure(kind=Missing, message="missing"),
    )
    let response = @router.default_decode_failure(
      @endpoint.FailureContext::new(
        @model.Request::post("/"),
        doc,
        [failure],
        Security,
      ),
    )
    assert_eq(response.status, expected)
  }
  let atom = @endpoint.Atom::new(RawBody, "body", @schema.raw_bytes.schema())
  for
    (failure, status) in [
      (@schema.DecodeFailure(kind=TooLarge(limit=3), message="too large"), 413),
      (
        @schema.DecodeFailure(
          kind=UnsupportedMediaType("unknown"),
          message="unsupported",
        ),
        415,
      ),
    ] {
    let response = @router.default_decode_failure(
      @endpoint.FailureContext::new(
        @model.Request::post("/"),
        doc,
        [@endpoint.InputFailure::new(atom, failure)],
        Body,
      ),
    )
    assert_eq(response.status, status)
  }
}

///|
test "handler errors use opaque defaults or the configured error policy" {
  let endpoint = @endpoint.endpoint
    .get("/fail")
    .serve_public(_ => raise Failure("secret internal detail"))
  let normal = @router.Router::new([endpoint])
  let custom = @router.Router::new([endpoint], options={
    ..@router.ServerOptions::default(),
    on_unhandled: (_, _) => Some(@model.Response::new(502)),
  })
  @driver.run_sync(() => {
    let response = normal.dispatch(@model.Request::get("/fail"))
    assert_eq(response.status, 500)
    assert_eq(
      response.body,
      @model.Bytes(
        @model.encode_utf8(
          "{\"type\":\"about:blank\",\"title\":\"Internal Server Error\",\"status\":500,\"errors\":[]}",
        ),
      ),
    )
    assert_eq(custom.dispatch(@model.Request::get("/fail")).status, 502)
  })
  let rejected = try {
    ignore(
      @router.Router::new([], options={
        ..@router.ServerOptions::default(),
        max_issues: 0,
      }),
    )
    false
  } catch {
    @endpoint.DefinitionError(_) => true
  }
  assert_true(rejected)
}

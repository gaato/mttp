///|
test "public operations explicitly clear root security and protected operations override it" {
  let public = @endpoint.endpoint.get("/public")
  let private = @endpoint.endpoint.get("/private").security(@endpoint.bearer())
  let spec = @openapi.to_openapi(
    [public.doc(), private.doc()],
    @apispec.Info::new("Test", "1"),
  )
  assert_eq(spec.security, None)
  assert_eq(spec.paths["/public"].operations["get"].security, Some([]))
  let spec = { ..spec, security: Some([{ "global": [] }]), }
  let decoded : @apispec.OpenApi = @json.from_json(Json(spec))
  assert_eq(decoded.security, Some([{ "global": [] }]))
  assert_eq(decoded.paths["/public"].operations["get"].security, Some([]))
  assert_eq(
    decoded.paths["/private"].operations["get"].security,
    Some([{ "bearer": [] }]),
  )
  let json = Json(spec)
  assert_true(
    json
    is {
      "paths": { "/public": { "get": { "security": Array([]), .. }, .. }, .. },
      ..
    },
  )
}

///|
test "OpenAPI refuses duplicate union tags through the shared checker" {
  let case_ = @schema.case_("same", @schema.jint, (n : Int32) => Some(n), n => n)
  let ep = @endpoint.endpoint
    .get("/")
    .output(
      @endpoint.json_out(@schema.any_of("Duplicate", [case_, case_]).body()),
    )
  try
    ignore(@openapi.to_openapi([ep.doc()], @apispec.Info::new("Test", "1")))
  catch {
    @endpoint.DefinitionError(problems) =>
      assert_true(
        problems
        .iter()
        .any(p => p.fatal && p.message == "union Duplicate repeats the tag same"),
      )
  } noraise {
    _ => fail("invalid union accepted")
  }
}

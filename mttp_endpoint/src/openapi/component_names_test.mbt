///|
test "OpenAPI restricts component keys without restricting schema property names" {
  for name in ["", "space name", "a/b", "a~b", "日本", "line\nbreak"] {
    let codec = @schema.BodyCodec::new(
      "text/plain",
      _ => (),
      _ => b"",
      @schema.Schema::of({ "type": "string" }).named(name),
    )
    let endpoint = @endpoint.endpoint
      .get("/")
      .security(@endpoint.bearer(scheme_name=name))
      .output(@endpoint.json_out(codec))
    let problems = try {
      ignore(
        @openapi.to_openapi([endpoint.doc()], @apispec.Info::new("Test", "1")),
      )
      []
    } catch {
      @endpoint.DefinitionError(problems) => problems
    }
    assert_true(
      problems
      .iter()
      .any(p => p.message.has_prefix("invalid OpenAPI schema component name:")),
    )
    assert_true(
      problems
      .iter()
      .any(p => {
        p.message.has_prefix("invalid OpenAPI security scheme component name:")
      }),
    )
  }
  for name in ["a", "0", ".-_", "my.org_User-v2"] {
    let codec = @schema.BodyCodec::new(
      "application/json",
      _ => (),
      _ => b"{}",
      @schema.Schema::of({
        "type": "object",
        "properties": { "a/b~日本": { "type": "string" } },
      }).named(name),
    )
    let endpoint = @endpoint.endpoint
      .get("/")
      .security(@endpoint.bearer(scheme_name=name))
      .output(@endpoint.json_out(codec))
    let spec = @openapi.to_openapi(
      [endpoint.doc()],
      @apispec.Info::new("Test", "1"),
    )
    assert_eq(@openapi.check_references(spec), [])
    assert_true(spec.components.schemas.contains(name))
    assert_true(spec.components.security_schemes.contains(name))
  }
}

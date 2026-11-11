///|
test "projection refuses duplicate named input parameters instead of emitting invalid operations" {
  for
    input in [
      @endpoint.pair(
        @endpoint.header("x", @schema.string),
        @endpoint.header("X", @schema.string),
      ),
      @endpoint.pair(
        @endpoint.query("q", @schema.string),
        @endpoint.query("q", @schema.string),
      ),
      @endpoint.pair(
        @endpoint.cookie("c", @schema.string),
        @endpoint.cookie("c", @schema.string),
      ),
    ] {
    let ep = @endpoint.endpoint.get("/duplicate").input(input)
    let raw = ep
      .request((), ("value", "value"))
      .raw()
      .set_header("x", "value")
      .set_header("cookie", "c=value")
    let request = if input.atoms()[0].location is Query {
      { ..raw, url: "/duplicate?q=value", }
    } else {
      raw
    }
    assert_eq(
      dispatch(
        ep.serve_public(value => {
          assert_eq(value, ("value", "value"))
          Ok(())
        }),
        request,
      ).status,
      200,
    )
    try ignore(project(ep.doc())) catch {
      @endpoint.DefinitionError(problems) =>
        assert_true(
          problems
          .iter()
          .any(p => p.message.has_prefix("duplicate OpenAPI parameter ")),
        )
    } noraise {
      _ => fail("duplicate parameters projected")
    }
  }
}

///|
test "projection refuses header parameters that OpenAPI would silently ignore" {
  for name in ["Accept", "content-TYPE", "AUTHORIZATION"] {
    let ep = @endpoint.endpoint
      .post("/reserved")
      .input(@endpoint.header(name, @schema.string))
    assert_eq(
      dispatch(
        ep.serve_public(value => {
          assert_eq(value, "value")
          Ok(())
        }),
        ep.request((), "value").raw(),
      ).status,
      200,
    )
    try ignore(project(ep.doc())) catch {
      @endpoint.DefinitionError(problems) =>
        assert_true(
          problems
          .iter()
          .any(p => p.message.has_prefix("OpenAPI ignores header parameter ")),
        )
    } noraise {
      _ => fail("ignored header parameter projected")
    }
  }
}

///|
test "output Content-Type must come from a representation rather than an ignored Header Object" {
  let ep = @endpoint.endpoint
    .get("/reserved-output")
    .output(@endpoint.no_content().and_header("Content-Type", @schema.string))
  try ignore(project(ep.doc())) catch {
    @endpoint.DefinitionError(problems) =>
      assert_true(problems.iter().any(p => p.fatal))
  } noraise {
    _ => fail("ignored Content-Type output header projected")
  }
}

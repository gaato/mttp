///|
test "every security scheme round trips and documents its real wire location" {
  let basic = @endpoint.basic(scheme_name="credential").map(
    pair => pair.0 + ":" + pair.1,
    value => {
      let parts = value.split_once(":").unwrap()
      (parts.0.to_owned(), parts.1.to_owned())
    },
  )
  for
    (kind, input, value) in [
      ("bearer", @endpoint.bearer(scheme_name="credential"), "secret"),
      ("basic", basic, "user:pass"),
      (
        "header",
        @endpoint.api_key_header("x-key", scheme_name="credential"),
        "secret",
      ),
      (
        "query",
        @endpoint.api_key_query("key", scheme_name="credential"),
        "secret",
      ),
      (
        "cookie",
        @endpoint.api_key_cookie("key", scheme_name="credential"),
        "secret",
      ),
      ("signature", @endpoint.signature_header("x-signature"), "secret"),
    ] {
    let ep = @endpoint.endpoint
      .post("/secure")
      .security(input)
      .output(@endpoint.text_out())
    let spec = project(ep.doc())
    let op = spec.paths["/secure"].operations["post"]
    let server = ep.serve(
      credentials => {
        assert_eq(credentials, value)
        Ok(())
      },
      (_, _) => Ok("ok"),
    )
    let response = dispatch(server, ep.request(value, ()).raw())
    assert_eq(response.status, 200)
    assert_eq(response.body, @mttp_core.Body::Bytes(b"ok"))
    let missing = dispatch(server, @mttp_core.Request::post("/secure"))
    assert_eq(missing.status, 401)
    assert_eq(@openapi.check_documented(spec, "/secure", Post, 401), None)
    if kind == "signature" {
      assert_eq(spec.components.security_schemes.length(), 0)
      assert_eq(op.security, Some([]))
      assert_eq(
        (op.parameters[0].name, op.parameters[0].in_, op.parameters[0].required),
        ("x-signature", "header", true),
      )
    } else {
      assert_eq(op.security, Some([{ "credential": [] }]))
      assert_eq(op.parameters.length(), 0)
      let scheme = spec.components.security_schemes["credential"]
      if kind == "bearer" || kind == "basic" {
        assert_eq((scheme.type_, scheme.scheme), ("http", Some(kind)))
      } else {
        assert_eq((scheme.type_, scheme.in_), ("apiKey", Some(kind)))
        assert_eq(
          scheme.name,
          Some(if kind == "header" { "x-key" } else { "key" }),
        )
      }
    }
  }
}

///|
test "optional AND security documents the anonymous and required-only alternatives" {
  let security = @endpoint.pair(
    @endpoint.bearer(scheme_name="token"),
    @endpoint.api_key_query("key", scheme_name="key").optional(),
  )
  let ep = @endpoint.endpoint.get("/mixed").security(security)
  let op = project(ep.doc()).paths["/mixed"].operations["get"]
  assert_eq(op.security, Some([{ "token": [] }, { "token": [], "key": [] }]))
  for optional in [None, Some("extra")] {
    assert_eq(
      dispatch(
        ep.serve(
          value => {
            assert_eq(value, ("secret", optional))
            Ok(())
          },
          (_, _) => Ok(()),
        ),
        ep.request(("secret", optional), ()).raw(),
      ).status,
      200,
    )
  }
  let ep = @endpoint.endpoint
    .get("/optional-auth")
    .security(
      @endpoint.pair(@endpoint.basic(), @endpoint.api_key_header("x-key")).optional(),
    )
  assert_eq(
    project(ep.doc()).paths["/optional-auth"].operations["get"].security,
    Some([{}, { "basic": [], "apiKey": [] }]),
  )
  let server = ep.serve(_ => Ok(()), (_, _) => Ok(()))
  assert_eq(dispatch(server, ep.request(None, ()).raw()).status, 200)
  assert_eq(
    dispatch(server, ep.request(Some((("u", "p"), "secret")), ()).raw()).status,
    200,
  )
}

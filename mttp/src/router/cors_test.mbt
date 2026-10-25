///|
test "CORS reflects only allowed origins and uses route methods for preflight" {
  let endpoint = @endpoint.endpoint.get("/").serve_public(_ => ())
  let router = @router.Router::new([endpoint], options={
    ..@router.ServerOptions::default(),
    middleware: [@router.cors(["https://client.test"])],
  })
  @driver.run_sync(() => {
    for
      headers in [
        @model.Headers::empty(),
        @model.Headers::of([("origin", "https://other.test")]),
        @model.Headers::of([("origin", "https://client.test")]),
        @model.Headers::of([("origin", "a"), ("origin", "b")]),
      ] {
      let response = router.dispatch({ ..@model.Request::get("/"), headers, })
      assert_eq(response.headers.get_all("vary"), ["Origin"])
    }
    let request = @model.Request::get("/").header(
      "origin", "https://client.test",
    )
    assert_eq(
      router.dispatch(request).headers.get("access-control-allow-origin"),
      Some("https://client.test"),
    )
    assert_eq(
      router.dispatch(
        @model.Request::get("/").header("origin", "https://other.test"),
      ).headers.get("access-control-allow-origin"),
      None,
    )
    assert_eq(
      router.dispatch(@model.Request::get("/")).headers.get(
        "access-control-allow-origin",
      ),
      None,
    )
    let preflight = @model.Request::new(Options, "/")
      .header("origin", "https://client.test")
      .header("access-control-request-method", "GET")
      .header("access-control-request-headers", "x-custom")
    let response = router.dispatch(preflight)
    assert_eq(response.status, 204)
    assert_eq(
      response.headers.get("access-control-allow-methods"),
      Some("GET, HEAD, OPTIONS"),
    )
    assert_eq(
      response.headers.get("access-control-allow-headers"),
      Some("x-custom"),
    )
    let response = router.dispatch({
      ..preflight,
      headers: preflight.headers.set("access-control-request-method", "DELETE"),
    })
    assert_eq(response.headers.get("access-control-allow-methods"), None)
  })
  for credentials in [false, true] {
    let router = @router.Router::new([endpoint], options={
      ..@router.ServerOptions::default(),
      middleware: [@router.cors(["*"], allow_credentials=credentials)],
    })
    @driver.run_sync(() => {
      assert_eq(
        router.dispatch(@model.Request::get("/")).headers.get("vary"),
        if credentials {
          Some("Origin")
        } else {
          None
        },
      )
      let response = router.dispatch(
        @model.Request::get("/").header("origin", "https://client.test"),
      )
      assert_eq(
        response.headers.get("access-control-allow-origin"),
        Some(if credentials { "https://client.test" } else { "*" }),
      )
      assert_eq(
        response.headers.get("access-control-allow-credentials"),
        if credentials {
          Some("true")
        } else {
          None
        },
      )
    })
  }
}

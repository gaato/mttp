///|
test "CORS reflects only allowed origins and uses route methods for preflight" {
  let endpoint = @endpoint.endpoint.get("/").serve_public(_ => Ok(()))
  let router = @router.Router::new([endpoint], options={
    ..@router.ServerOptions::default(),
    middleware: [@router.cors(["https://client.test"])],
  })
  @driver.run_sync(() => {
    for
      headers in [
        @http.Headers::empty(),
        @http.Headers::of([("origin", "https://other.test")]),
        @http.Headers::of([("origin", "https://client.test")]),
        @http.Headers::of([("origin", "a"), ("origin", "b")]),
      ] {
      let response = router.dispatch({ ..@http.Request::get("/"), headers, })
      assert_eq(response.headers.get_all("vary"), ["Origin"])
    }
    let request = @http.Request::get("/").header(
      "origin", "https://client.test",
    )
    assert_eq(
      router.dispatch(request).headers.get("access-control-allow-origin"),
      Some("https://client.test"),
    )
    assert_eq(
      router.dispatch(
        @http.Request::get("/").header("origin", "https://other.test"),
      ).headers.get("access-control-allow-origin"),
      None,
    )
    assert_eq(
      router.dispatch(@http.Request::get("/")).headers.get(
        "access-control-allow-origin",
      ),
      None,
    )
    let preflight = @http.Request::new(Options, "/")
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
    for
      request in [
        @http.Request::options("/"),
        @http.Request::options("/").header("origin", "https://other.test"),
        @http.Request::options("/").header("origin", "https://client.test"),
      ] {
      assert_eq(router.dispatch(request).headers.get_all("vary"), [
        "Origin", "Access-Control-Request-Method, Access-Control-Request-Headers",
      ])
    }
  })
  for credentials in [false, true] {
    let router = @router.Router::new([endpoint], options={
      ..@router.ServerOptions::default(),
      middleware: [@router.cors(["*"], allow_credentials=credentials)],
    })
    @driver.run_sync(() => {
      assert_eq(
        router.dispatch(@http.Request::get("/")).headers.get("vary"),
        if credentials {
          Some("Origin")
        } else {
          None
        },
      )
      let response = router.dispatch(
        @http.Request::get("/").header("origin", "https://client.test"),
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

///|
test "CORS preserves existing Vary and wildcard replies cannot be primed without Origin" {
  let vary : @router.Middleware = (request, next) => {
    let response = next(request)
    { ..response, headers: response.headers.add("vary", "Accept-Encoding"), }
  }
  let ep = @endpoint.endpoint.get("/").serve_public(_ => Ok(()))
  for origins in [["https://client.test"], ["*"]] {
    let router = @router.Router::new([ep], options={
      ..@router.ServerOptions::default(),
      middleware: [@router.cors(origins), vary],
    })
    @driver.run_sync(() => {
      let response = router.dispatch(@http.Request::get("/"))
      assert_eq(
        response.headers.get_all("vary"),
        if origins == ["*"] {
          ["Accept-Encoding"]
        } else {
          ["Accept-Encoding", "Origin"]
        },
      )
      assert_eq(
        response.headers.get("access-control-allow-origin"),
        if origins == ["*"] {
          Some("*")
        } else {
          None
        },
      )
    })
  }
}

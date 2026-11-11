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
        @mttp.Headers::empty(),
        @mttp.Headers::of([("origin", "https://other.test")]),
        @mttp.Headers::of([("origin", "https://client.test")]),
        @mttp.Headers::of([("origin", "a"), ("origin", "b")]),
      ] {
      let response = router.dispatch({ ..@mttp.Request::get("/"), headers, })
      assert_eq(response.headers.get_all("vary"), ["Origin"])
    }
    let request = @mttp.Request::get("/").header(
      "origin", "https://client.test",
    )
    assert_eq(
      router.dispatch(request).headers.get("access-control-allow-origin"),
      Some("https://client.test"),
    )
    assert_eq(
      router.dispatch(
        @mttp.Request::get("/").header("origin", "https://other.test"),
      ).headers.get("access-control-allow-origin"),
      None,
    )
    assert_eq(
      router.dispatch(@mttp.Request::get("/")).headers.get(
        "access-control-allow-origin",
      ),
      None,
    )
    let preflight = @mttp.Request::new(Options, "/")
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
        @mttp.Request::options("/"),
        @mttp.Request::options("/").header("origin", "https://other.test"),
        @mttp.Request::options("/").header("origin", "https://client.test"),
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
        router.dispatch(@mttp.Request::get("/")).headers.get("vary"),
        if credentials {
          Some("Origin")
        } else {
          None
        },
      )
      let response = router.dispatch(
        @mttp.Request::get("/").header("origin", "https://client.test"),
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
      let response = router.dispatch(@mttp.Request::get("/"))
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

///|
test "CORS exposes declared and listed response headers to allowed origins" {
  let failing = Ref(false)
  let tagged = @endpoint.endpoint
    .get("/tagged")
    .errors(@endpoint.text_out(status=412).and_header("ETag", @schema.string))
    .output(@endpoint.text_out().and_header("ETag", @schema.string))
    .serve_public(_ => {
      if failing.val {
        Err(("stale", "\"v2\""))
      } else {
        Ok(("fresh", "\"v1\""))
      }
    })
  let plain = @endpoint.endpoint.get("/plain").serve_public(_ => Ok(()))
  let listed = [
    "X-Request-Id", "Content-Type", "x-request-id", "etag", "cache-control",
  ]
  for
    (middleware, other_allowed, tagged_exposed, plain_exposed) in [
      (@router.cors(["https://client.test"]), false, ["ETag"], []),
      (@router.cors(["*"]), true, ["ETag"], []),
      (
        @router.cors(["https://client.test"], expose_headers=listed),
        false,
        ["X-Request-Id, etag"],
        ["X-Request-Id, etag"],
      ),
    ] {
    let router = @router.Router::new([tagged, plain], options={
      ..@router.ServerOptions::default(),
      middleware: [middleware],
    })
    @driver.run_sync(() => {
      let exposed = (request : @mttp.Request) => {
        router.dispatch(request).headers.get_all(
          "access-control-expose-headers",
        )
      }
      let from = (path, origin) => {
        @mttp.Request::get(path).header("origin", origin)
      }
      failing.val = false
      let response = router.dispatch(from("/tagged", "https://client.test"))
      assert_eq(response.status, 200)
      assert_eq(
        response.headers.get_all("access-control-expose-headers"),
        tagged_exposed,
      )
      failing.val = true
      let response = router.dispatch(from("/tagged", "https://client.test"))
      assert_eq(response.status, 412)
      assert_eq(
        response.headers.get_all("access-control-expose-headers"),
        tagged_exposed,
      )
      assert_eq(exposed(from("/plain", "https://client.test")), plain_exposed)
      // A denied origin and a request without Origin expose nothing.
      assert_eq(
        exposed(from("/tagged", "https://other.test")),
        if other_allowed {
          tagged_exposed
        } else {
          []
        },
      )
      assert_eq(exposed(@mttp.Request::get("/tagged")), [])
      // Browsers read exposed headers from the actual response only.
      let preflight = @mttp.Request::new(Options, "/tagged")
        .header("origin", "https://client.test")
        .header("access-control-request-method", "GET")
      assert_eq(exposed(preflight), [])
    })
  }
}

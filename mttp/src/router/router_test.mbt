///|
test "literal routes win without falling through and HEAD OPTIONS are automatic" {
  let dynamic = @endpoint.endpoint
    .get("/items/{id}")
    .input(@endpoint.path("id", @schema.string))
    .output(@endpoint.json_out(@schema.text_body))
    .serve_public(id => id)
  let literal = @endpoint.endpoint.post("/items/new").serve_public(_ => ())
  let router = @router.Router::new([dynamic, literal])
  @driver.run_sync(() => {
    assert_eq(router.dispatch(@model.Request::get("/items/new")).status, 405)
    let response = router.dispatch(@model.Request::get("/items/abc"))
    assert_eq(response.body, @model.Bytes(b"abc"))
    assert_eq(
      response.attributes.get(@endpoint.route_template),
      Some("/items/{id}"),
    )
    let response = router.dispatch(@model.Request::new(Head, "/items/abc"))
    assert_eq(response.status, 200)
    assert_eq(response.body, @model.Empty)
    let response = router.dispatch(@model.Request::new(Options, "/items/abc"))
    assert_eq(response.status, 204)
    assert_eq(response.headers.get("allow"), Some("GET, HEAD, OPTIONS"))
    assert_eq(router.dispatch(@model.Request::get("/unknown")).status, 404)
    assert_eq(router.dispatch(@model.Request::get("/bad path")).status, 400)
  })
}

///|
test "definition checks refuse ambiguous routes and repeated operation IDs" {
  let a = @endpoint.endpoint
    .get("/a/{id}")
    .input(@endpoint.path("id", @schema.string))
  let b = @endpoint.endpoint
    .get("/a/{other}")
    .input(@endpoint.path("other", @schema.string))
  let refused = try {
    ignore(
      @router.Router::new([a.serve_public(_ => ()), b.serve_public(_ => ())]),
    )
    false
  } catch {
    @endpoint.DefinitionError(_) => true
  }
  assert_true(refused)
  let docs = [
    @endpoint.endpoint.get("/one").operation_id("one").doc(),
    @endpoint.endpoint.post("/two").operation_id("one").doc(),
  ]
  assert_true(@endpoint.check_definitions(docs).iter().any(p => p.fatal))
  for
    doc in [
      @endpoint.endpoint.get("relative").doc(),
      @endpoint.endpoint
      .get("/{id}/{id}")
      .input(@endpoint.path("id", @schema.string))
      .doc(),
      @endpoint.endpoint.post("/negative").max_body_bytes(-1).doc(),
      @endpoint.endpoint.get("/empty/").doc(),
    ] {
    assert_true(!doc.problems().is_empty())
  }
}

///|
test "router backend strips local attributes and enforces closed state" {
  let router = @router.Router::new([
    @endpoint.endpoint
    .get("/ip")
    .input(@endpoint.attribute(@model.remote_addr))
    .output(@endpoint.json_out(@schema.text_body))
    .serve_public(address => address.unwrap_or("missing")),
  ])
  @driver.run_sync(() => {
    let request = @model.Request::get("/ip").attribute(
      @model.remote_addr, "caller",
    )
    let response = router.send(request, @client.RequestOptions::default())
    assert_eq(response.body, @model.Bytes(b"in-process"))
    assert_eq(response.attributes.get(@endpoint.route_template), None)
    router.close()
    router.close()
    let refused = try {
      ignore(router.send(request, @client.RequestOptions::default()))
      false
    } catch {
      @model.TransportError(kind=Closed, ..) => true
      _ => false
    }
    assert_true(refused)
    assert_eq(router.dispatch(request).status, 503)
  })
}

///|
test "exact paths outrank empty rests regardless of route registration order" {
  let exact = @endpoint.endpoint
    .get("/a")
    .output(@endpoint.text_out())
    .serve_public(_ => "exact")
  let rest = @endpoint.endpoint
    .get("/a/{tail...}")
    .input(@endpoint.paths("tail"))
    .output(@endpoint.text_out())
    .serve_public(_ => "rest")
  for endpoints in [[exact, rest], [rest, exact]] {
    let router = @router.Router::new(endpoints)
    assert_eq(router.docs().length(), 2)
    @driver.run_sync(() => {
      assert_eq(
        router.dispatch(@model.Request::get("/a")).body,
        @model.Bytes(b"exact"),
      )
      assert_eq(router.dispatch(@model.Request::get("/")).status, 404)
      assert_eq(
        router.dispatch(@model.Request::get("/a/b")).body,
        @model.Bytes(b"rest"),
      )
    })
  }
}

///|
test "middleware forwarded requests are validated before route decoding" {
  let middleware : @router.Middleware = (request, next) => {
    next({ ..request, url: "http://[", })
  }
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [middleware],
  })
  @driver.run_sync(() => {
    assert_eq(router.dispatch(@model.Request::get("/")).status, 400)
  })
}

///|
test "authentication failures are opaque with a challenge" {
  let router = @router.Router::new([
    @endpoint.endpoint
    .get("/private")
    .security(@endpoint.bearer())
    .serve(_ => (), (_, _) => ()),
  ])
  @driver.run_sync(() => {
    let response = router.dispatch(@model.Request::get("/private"))
    assert_eq(response.status, 401)
    assert_eq(response.headers.get("www-authenticate"), Some("Bearer"))
    assert_eq(
      response.headers.get("content-type"),
      Some("application/problem+json"),
    )
  })
}

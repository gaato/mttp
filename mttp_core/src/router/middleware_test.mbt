///|
test "request IDs preserve single values and access logs include route metadata" {
  let clock = @sim.FakeClock::new()
  let generated = Ref(0)
  let log : Array[(String, Int32, String?, Int64)] = []
  let ep = @endpoint.endpoint
    .get("/logged")
    .input(@endpoint.header("x-request-id", @schema.string))
    .output(@endpoint.text_out())
    .serve_public(id => {
      clock.advance(7)
      Ok(id)
    })
  let router = @router.Router::new([ep], options={
    ..@router.ServerOptions::default(),
    middleware: [
      @router.request_id(generate=() => {
        generated.val += 1
        "generated"
      }),
      @router.access_log(clock, (request, response, elapsed) => {
        log.push(
          (
            request.headers.get("x-request-id").unwrap(),
            response.status,
            response.attributes.get(@endpoint.route_template),
            elapsed,
          ),
        )
      }),
    ],
  })
  @driver.run_sync(() => {
    for
      (headers, expected) in [
        (@mttp_core.Headers::empty(), "generated"),
        (@mttp_core.Headers::of([("x-request-id", "caller")]), "caller"),
        (@mttp_core.Headers::of([("x-request-id", "")]), "generated"),
        (
          @mttp_core.Headers::of([("x-request-id", "a"), ("x-request-id", "b")]),
          "generated",
        ),
      ] {
      let response = router.dispatch({
        ..@mttp_core.Request::get("/logged"),
        headers,
      })
      assert_eq(response.headers.get("x-request-id"), Some(expected))
      assert_eq(
        response.body,
        @mttp_core.Body::Bytes(@mttp_core.encode_utf8(expected)),
      )
      assert_eq(log.last(), Some((expected, 200, Some("/logged"), 7L)))
    }
  })
  assert_eq(generated.val, 3)
  let random = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [@router.request_id()],
  })
  @driver.run_sync(() => {
    assert_true(
      random.dispatch(@mttp_core.Request::get("/")).headers
      .get("x-request-id")
      .unwrap()
      .length() >
      0,
    )
  })
}

///|
test "authentication hiding applies only to failed authentication inputs" {
  let router = @router.Router::new(
    [
      @endpoint.endpoint
      .get("/private")
      .security(@endpoint.bearer())
      .serve(_ => Ok(()), (_, _) => Ok(())),
      @endpoint.endpoint
      .get("/query")
      .input(@endpoint.query("q", @schema.int))
      .serve_public(_ => Ok(())),
    ],
    options={
      ..@router.ServerOptions::default(),
      decode_failure: @router.hide_endpoints_with_auth,
    },
  )
  @driver.run_sync(() => {
    let hidden = router.dispatch(@mttp_core.Request::get("/private"))
    assert_eq(hidden.status, 404)
    assert_eq(hidden.headers.get("www-authenticate"), None)
    assert_eq(router.dispatch(@mttp_core.Request::get("/query")).status, 400)
    assert_eq(
      router.dispatch(@mttp_core.Request::get("/private").bearer("ok")).status,
      200,
    )
  })
}

///|
test "HEAD explicit routes and early failures always omit and close bodies" {
  let calls = Ref(0)
  let router = @router.Router::new([
    @endpoint.endpoint
    .get("/")
    .output(@endpoint.text_out())
    .serve_public(_ => Ok("GET")),
    @endpoint.endpoint
    .head("/")
    .output(@endpoint.text_out())
    .serve_public(_ => {
      calls.val += 1
      Ok("HEAD")
    }),
    @endpoint.endpoint.options("/").serve_public(_ => Ok(())),
  ])
  @driver.run_sync(() => {
    assert_eq(router.dispatch(@mttp_core.Request::options("/")).status, 200)
    let response = router.dispatch(@mttp_core.Request::new(Head, "/"))
    assert_eq(response.body, @mttp_core.Body::Empty)
    assert_eq(calls.val, 1)
    let response = router.dispatch(@mttp_core.Request::new(Head, "/bad path"))
    assert_eq(response.status, 400)
    assert_eq(response.body, @mttp_core.Body::Empty)
    router.close()
    let response = router.dispatch(@mttp_core.Request::new(Head, "/"))
    assert_eq(response.status, 503)
    assert_eq(response.body, @mttp_core.Body::Empty)
  })
}

///|
test "default decode failures retain nested validation paths and issue codes" {
  let ep = @endpoint.endpoint
    .post("/")
    .input(@endpoint.body(@schema.array(@schema.jint).body()))
  let router = @router.Router::new([ep.serve_public(_ => Ok(()))])
  @driver.run_sync(() => {
    let response = router.dispatch(
      @mttp_core.Request::post("/").body_json(["bad"]),
    )
    assert_eq(response.status, 400)
    guard response.body is Bytes(bytes) else { fail("missing problem") }
    assert_true(
      @schema.jvalue.body().decode(bytes)
      is {
        "errors": Array([{ "path": String("/0"), "code": String(_), .. }]),
        ..
      },
    )
  })
}

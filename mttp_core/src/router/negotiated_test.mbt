///|
test "Router negotiated output selects Accept adds Vary and returns 406 or 400" {
  let text = @endpoint.json_variant(200, @schema.text_body).fixed_header(
    "vary", "Origin",
  )
  let html = @endpoint.json_variant(200, @schema.html_body)
  let output = @endpoint.one_of([text, html])
    .negotiated()
    .and_header("x-value", @schema.int)
  let ep = @endpoint.endpoint.get("/").output(output)
  let router = @router.Router::new([ep.serve_public(_ => Ok(("hello", 7)))])
  let ordinary = @router.Router::new([
    @endpoint.endpoint
    .get("/")
    .output(@endpoint.one_of([text, html]))
    .serve_public(_ => Ok("hello")),
  ])
  @driver.run_sync(() => {
    for
      (accept, status, media) in [
        ("text/html", 200, Some("text/html; charset=utf-8")),
        ("text/plain;q=0.9,text/html;q=0.2", 200, Some("text/plain")),
        ("image/png", 406, None),
        ("text/plain;q=2", 400, None),
        (String::make(16385, 'a'), 400, None),
      ] {
      let request = @mttp_core.Request::get("/").header("accept", accept)
      let response = router.dispatch(request)
      assert_eq(response.status, status)
      assert_eq(response.headers.get("content-type"), media)
      assert_true(
        response.headers.get_all("vary").iter().any(v => v == "Accept"),
      )
      if status == 200 {
        assert_eq(response.body, @mttp_core.Bytes(b"hello"))
        assert_eq(response.headers.get("x-value"), Some("7"))
      }
    }
    let response = router.dispatch(@mttp_core.Request::get("/"))
    assert_eq(response.headers.get_all("vary"), ["Origin", "Accept"])
    assert_eq(
      ordinary.dispatch(
        @mttp_core.Request::get("/").header("accept", "image/png"),
      ).status,
      200,
    )
    let response = router.dispatch(
      @mttp_core.Request::new(Head, "/").header("accept", "text/html"),
    )
    assert_eq(response.status, 200)
    assert_eq(response.body, @mttp_core.Empty)
  })
  assert_true(
    ep.doc().outputs.iter().any(v => v.status == 406 && v.media_type is None),
  )
}

///|
test "Router negotiated dynamic media uses actual content type and bodyless outputs proceed" {
  let router = @router.Router::new([
    @endpoint.endpoint
    .get("/dynamic")
    .output(@endpoint.body_out().negotiated().and_status().set_cookie("id"))
    .serve_public(_ => Ok(((("image/png", b"png"), 201), "7"))),
    @endpoint.endpoint
    .get("/empty")
    .output(@endpoint.no_content().negotiated())
    .serve_public(_ => Ok(())),
    @endpoint.endpoint
    .get("/invalid")
    .output(@endpoint.body_out().and_status().negotiated())
    .serve_public(_ => Ok((("image/png", b"png"), 99))),
    @endpoint.endpoint
    .get("/nomatch")
    .output(
      @endpoint.one_of([
        @endpoint.json_variant(200, @schema.text_body).contramap(
          (_ : String) => None,
          value => value,
        ),
      ]).negotiated(),
    )
    .serve_public(_ => Ok("value")),
  ])
  @driver.run_sync(() => {
    assert_eq(
      router.dispatch(
        @mttp_core.Request::get("/dynamic").header("accept", "text/plain;q=2"),
      ).status,
      400,
    )
    assert_eq(router.dispatch(@mttp_core.Request::get("/invalid")).status, 500)
    assert_eq(router.dispatch(@mttp_core.Request::get("/nomatch")).status, 500)
    assert_eq(
      router.dispatch(
        @mttp_core.Request::get("/dynamic").header("accept", "text/plain"),
      ).status,
      406,
    )
    let response = router.dispatch(
      @mttp_core.Request::get("/dynamic").header("accept", "image/*"),
    )
    assert_eq(response.status, 201)
    assert_eq(response.body, @mttp_core.Bytes(b"png"))
    assert_eq(response.headers.get("set-cookie"), Some("id=7"))
    assert_eq(
      router.dispatch(
        @mttp_core.Request::get("/empty").header("accept", "image/png"),
      ).status,
      204,
    )
  })
}

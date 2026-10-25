///|
test "security runs before input rejection and malformed credentials are refused" {
  let authenticated = Ref(0)
  let handled = Ref(0)
  let ep = @endpoint.endpoint
    .post("/items")
    .security(@endpoint.bearer())
    .input(@endpoint.body(@schema.text_body))
    .serve(
      token => {
        assert_eq(token, "token")
        authenticated.val += 1
      },
      (_, _) => handled.val += 1,
    )
  let stages = []
  let ctx = @endpoint.DispatchContext::new(decode_failure=f => {
    stages.push(f.stage)
    @model.Response::new(400)
  })
  @driver.run_sync(() => {
    let request = @model.Request::post("/items").header(
      "Authorization", "bEaReR  token",
    )
    assert_eq(ep.dispatch(request, Map([]), ctx).status, 400)
    assert_eq(authenticated.val, 1)
    assert_eq(stages, [@endpoint.Head])
    for value in ["Bearer ", "Bearer a b", "Basic abc"] {
      let request = @model.Request::post("/items").header(
        "authorization", value,
      )
      assert_eq(ep.dispatch(request, Map([]), ctx).status, 400)
    }
    let request = request.header("authorization", "Bearer other")
    assert_eq(ep.dispatch(request, Map([]), ctx).status, 400)
  })
  assert_eq(authenticated.val, 1)
  assert_eq(handled.val, 0)
  assert_eq(stages.length(), 5)
  for stage in stages[1:] {
    assert_eq(stage, @endpoint.Security)
  }
}

///|
test "body media type is exact and raw security body is encoded" {
  let ep = @endpoint.endpoint
    .post("/text")
    .input(@endpoint.body(@schema.text_body))
    .output(@endpoint.json_out(@schema.text_body))
  let server = ep.serve_public(text => text)
  @driver.run_sync(() => {
    for content_type in ["text/plain junk", "text/plainx", "application/json"] {
      let request = @model.Request::post("/text")
        .header("content-type", content_type)
        .body_bytes(b"hello")
      assert_eq(
        server.dispatch(request, Map([]), @endpoint.DispatchContext::new()).status,
        400,
      )
    }
    let request = @model.Request::post("/text")
      .header("content-type", "Text/Plain ; charset=utf-8")
      .body_bytes(b"hello")
    let response = server.dispatch(
      request,
      Map([]),
      @endpoint.DispatchContext::new(),
    )
    assert_eq(response.status, 200)
    assert_eq(response.body, @model.Bytes(b"hello"))
    assert_eq(response.attributes.get(@endpoint.route_template), Some("/text"))
  })
  let signed = @endpoint.endpoint.post("/signed").security(@endpoint.raw_body())
  assert_eq(
    signed.request(b"signed bytes", ()).raw().body,
    @model.Bytes(b"signed bytes"),
  )
}

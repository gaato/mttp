///|
test "typed client round trips repeated queries cookies basic auth and headers" {
  let input = @endpoint.Input::map3(
    @endpoint.query_list("q", @schema.int),
    @endpoint.cookie("session", @schema.string),
    @endpoint.header("x-value", @schema.int),
    (queries, cookie, header) => (queries, cookie, header),
    value => value,
  )
  let ep = @endpoint.endpoint
    .get("/roundtrip")
    .security(@endpoint.basic())
    .input(input)
    .output(@endpoint.text_out().and_header("x-count", @schema.int))
  let server = ep.serve(
    credentials => assert_eq(credentials, ("user", "pass:word")),
    (_, input) => {
      assert_eq(input, ([1, 2], "cookie", 7))
      ("ok", 2)
    },
  )
  let router = @router.Router::new([server])
  let client = @client.Client::new(router, @fake.FakeClock::new())
  @driver.run_sync(() => {
    assert_eq(
      ep.call(client, ("user", "pass:word"), ([1, 2], "cookie", 7)),
      ("ok", 2),
    )
  })
  client.close()
}

///|
test "rest captures preserve encoded slashes empty segments and empty tails" {
  let ep = @endpoint.endpoint
    .get("/files/{tail...}")
    .input(@endpoint.paths("tail"))
    .output(@endpoint.json_out(@schema.array(@schema.jstring).body()))
  let exact = @endpoint.endpoint
    .get("/files/special")
    .output(@endpoint.text_out())
    .serve_public(_ => "specific")
  let router = @router.Router::new([ep.serve_public(parts => parts), exact])
  let client = @client.Client::new(router, @fake.FakeClock::new())
  @driver.run_sync(() => {
    for parts in [[], [""], ["a/b", "", "x y"]] {
      assert_eq(ep.call(client, (), parts), parts)
    }
    assert_eq(
      router.dispatch(@model.Request::get("/files/special")).body,
      @model.Bytes(b"specific"),
    )
  })
  client.close()
}

///|
test "SSE callback consumes events and closes exactly once" {
  let closed = Ref(0)
  let index = Ref(0)
  let ep = @endpoint.endpoint
    .get("/events")
    .output(@endpoint.sse_out(@schema.jint))
  let source = @endpoint.EventStream::from_pull(
    () => {
      index.val += 1
      if index.val <= 3 {
        Some(index.val)
      } else {
        None
      }
    },
    () => closed.val += 1,
  )
  let router = @router.Router::new([ep.serve_public(_ => source)])
  let client = @client.Client::new(router, @fake.FakeClock::new())
  let values = []
  @driver.run_sync(() => {
    ep.call_with(client, (), (), events => {
      events.each(value => values.push(value))
    })
  })
  assert_eq(values, [1, 2, 3])
  source.close()
  assert_eq(closed.val, 1)
  client.close()
}

///|
test "custom inputs work from outside the endpoint package" {
  let input = @endpoint.Input::new(
    [@endpoint.Atom::new(Header, "x-custom", @schema.string.schema())],
    head => {
      @endpoint.Staged::ready(
        head.request.headers.get("x-custom").unwrap_or("missing"),
      )
    },
    (value, sink) => sink.set_header("x-custom", value),
  )
  let ep = @endpoint.endpoint
    .get("/custom")
    .input(input)
    .output(@endpoint.text_out())
  let router = @router.Router::new([ep.serve_public(value => value)])
  let client = @client.Client::new(router, @fake.FakeClock::new())
  @driver.run_sync(() => assert_eq(ep.call(client, (), "custom"), "custom"))
  client.close()
}

///|
test "dynamic response status media type and separate cookies round trip" {
  let ep = @endpoint.endpoint
    .get("/dynamic")
    .output(@endpoint.body_out().and_status().set_cookie("a").set_cookie("b"))
  let value = (
    ((("multipart/mixed; boundary=test", b"payload"), 202), "one; Secure"),
    "two; HttpOnly",
  )
  let router = @router.Router::new([ep.serve_public(_ => value)])
  let client = @client.Client::new(router, @fake.FakeClock::new())
  @driver.run_sync(() => assert_eq(ep.call(client, (), ()), value))
  let doc = ep.doc().outputs[0]
  assert_true(doc.dynamic_status)
  assert_true(doc.dynamic_media)
  assert_eq(doc.header_schemas["set-cookie"].json, { "type": "string" })
  client.close()
}

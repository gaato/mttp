///|
test "jint refuses fractional and out-of-range numbers" {
  assert_eq(@schema.jint.from_json(Json::number(42.0)), 42)
  assert_true(
    (Some(@schema.jint.from_json(Json::number(1.5))) catch { _ => None })
    is None,
  )
  assert_true(
    (Some(@schema.jint.from_json(Json::number(4294967296.0))) catch {
      _ => None
    })
    is None,
  )
}

///|
test "SSE events survive a UTF-8 sequence split across chunks, with an output header" {
  let ep = @endpoint.endpoint
    .get("/events")
    .output(
      @endpoint.sse_out(@api.user_json).and_header("x-cursor", @schema.string),
    )
  let event = @utf8.encode("data: {\"id\":1,\"name\":\"caf\u{e9}\"}\n\n")
  // cut inside the two bytes of U+00E9
  let cut = event.length() - 5
  let backend = @client.from_fn((_, _) => {
    let chunks = [
      Bytes::from_array(event.to_array()[0:cut]),
      Bytes::from_array(event.to_array()[cut:]),
    ]
    @model.Response::new(
      200,
      headers=@model.Headers::of([
        ("content-type", "text/event-stream"),
        ("x-cursor", "c1"),
      ]),
      body=Stream(@model.BytesStream::new(chunks), length=None),
    )
  })
  let got = @testing.run_sync(async fn() {
    ep.call_with(@e2e.client(backend), (), (), async fn(out) {
      let (es, cursor) = out
      let names = []
      es.each(async fn(u) { names.push(u.name) })
      (names, cursor)
    })
  })
  assert_eq(got, (["caf\u{e9}"], "c1"))
}

///|
test "SSE events survive a UTF-8 sequence split across chunks" {
  let event = @utf8.encode("data: {\"id\":1,\"name\":\"caf\u{e9}\"}\n\n")
  let cut = event.length() - 5
  let backend = @client.from_fn((_, _) => {
    @model.Response::new(
      200,
      headers=@model.Headers::of([("content-type", "text/event-stream")]),
      body=Stream(
        @model.BytesStream::new([
          Bytes::from_array(event.to_array()[0:cut]),
          Bytes::from_array(event.to_array()[cut:]),
        ]),
        length=None,
      ),
    )
  })
  let names = @testing.run_sync(async fn() {
    @api.user_events.call_with(@e2e.client(backend), (), (), async fn(es) {
      let names = []
      es.each(async fn(u) { names.push(u.name) })
      names
    })
  })
  assert_eq(names, ["caf\u{e9}"])
}

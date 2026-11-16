///|
test "examples survive typed builders and docs are independent" {
  let base = @endpoint.endpoint
    .post("/examples")
    .request_example("request", 1, summary="one")
    .response_example(200, "response", 2)
  let ep = base
    .security(@endpoint.bearer())
    .input(@endpoint.body(@schema.jint.body()))
    .errors(@endpoint.text_out(status=409))
    .output(@endpoint.json_out(@schema.jint.body()))
  let doc = ep.doc()
  assert_eq(doc.request_examples, [("request", 1, Some("one"))])
  assert_eq(doc.response_examples, [(200, "response", 2, None)])
  assert_eq(@endpoint.check_definitions([doc]), [])
  doc.request_examples.clear()
  doc.response_examples.clear()
  assert_eq(ep.doc().request_examples.length(), 1)
  assert_eq(ep.doc().response_examples.length(), 1)
  let extended = ep.request_example("second", 3)
  assert_eq(extended.doc().request_examples.length(), 2)
  assert_eq(ep.doc().request_examples.length(), 1)
}

///|
test "definition checker refuses missing bodies undeclared statuses and duplicate example names" {
  let ep = @endpoint.endpoint
    .get("/bad")
    .request_example("x", 1)
    .request_example("x", 2)
    .response_example(201, "x", 1)
    .response_example(201, "x", 2)
  let problems = @endpoint.check_definitions([ep.doc()])
  assert_true(problems.iter().all(p => p.fatal))
  assert_eq(problems.map(p => p.message), [
    "duplicate request example x", "request example without a body", "response example for undeclared status 201",
    "duplicate response example 201:x", "response example for undeclared status 201",
  ])
  let good = @endpoint.endpoint
    .post("/good")
    .input(@endpoint.raw_body())
    .errors(@endpoint.text_out(status=409))
    .request_example("same", "raw")
    .response_example(200, "same", null)
    .response_example(409, "same", "conflict")
  assert_eq(@endpoint.check_definitions([good.doc()]), [])
}

///|
test "dynamic response examples accept final status boundaries and reject one past them" {
  let dynamic = @endpoint.endpoint
    .get("/dynamic")
    .output(@endpoint.text_out().and_status())
  assert_eq(
    @endpoint.check_definitions([
      dynamic
      .response_example(200, "low", "ok")
      .response_example(599, "high", "error")
      .doc(),
    ]),
    [],
  )
  for status in [199, 600] {
    assert_eq(
      @endpoint.check_definitions([
        dynamic.response_example(status, "outside", null).doc(),
      ]).map(p => p.message),
      ["response example for undeclared status " + status.to_string()],
    )
  }
}

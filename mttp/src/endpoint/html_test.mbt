///|
test "HTML pages round-trip as text/html and are documented as such" {
  let page = @endpoint.endpoint
    .get("/")
    .output(@endpoint.html_out())
    .errors(@endpoint.html_out(status=404))
  let missing = Ref(false)
  let content_types = []
  let server = page.serve_public(_ => {
    if missing.val {
      Err("<h1>Not found</h1>")
    } else {
      Ok("<h1>Links</h1>")
    }
  })
  let client = @client.Client::new(
    @client.from_handler(req => {
      let response = server.dispatch(req, {}, @endpoint.DispatchContext::new())
      content_types.push(response.headers.get("content-type"))
      response
    }),
    @sim.FakeClock::new(),
  )
  defer client.close()
  @driver.run_sync(() => {
    assert_eq(page.call(client, (), ()), Ok(Ok("<h1>Links</h1>")))
    missing.val = true
    assert_eq(page.call(client, (), ()), Ok(Err("<h1>Not found</h1>")))
  })
  assert_eq(content_types, [
    Some("text/html; charset=utf-8"),
    Some("text/html; charset=utf-8"),
  ])
  let doc = page.doc()
  assert_eq(doc.outputs[0].media_type, Some("text/html; charset=utf-8"))
  assert_eq(doc.errors[0].status, 404)
  assert_eq(doc.errors[0].media_type, Some("text/html; charset=utf-8"))
}

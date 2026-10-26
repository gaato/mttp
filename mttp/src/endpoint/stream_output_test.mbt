///|
test "dynamic body output preserves chunks and closes a partially read callback" {
  let driver = @driver.Driver::new()
  let source = @feed.Feed::bytes(driver, [b"first", b"second"])
  let ep = @endpoint.endpoint
    .get("/")
    .output(@endpoint.stream_body_out().and_status())
  let server = ep.serve_public(_ => {
    Ok(
      (
        (
          Some("multipart/form-data; boundary=test"),
          @model.Stream(@model.StreamBody::new(source)),
        ),
        202,
      ),
    )
  })
  let client = @client.Client::new(
    @client.from_fn((request, _) => {
      server.dispatch(request, {}, @endpoint.DispatchContext::new())
    }),
    @fake.FakeClock::new(),
  )
  defer client.close()
  driver.run(() => {
    ep
    .call_with(client, (), (), result => {
      assert_eq(result.1, 202)
      assert_eq(result.0.0, Some("multipart/form-data; boundary=test"))
      guard result.0.1 is Stream(body) else { fail("expected stream") }
      assert_eq(body.take().read_some(), Some(b"first"))
      assert_eq(source.closes(), 0)
    })
    .unwrap()
    .unwrap()
    assert_eq(source.closes(), 1)
  })
}

///|
test "dynamic body output buffers ordinary calls and permits absent content type" {
  let ep = @endpoint.endpoint.get("/").output(@endpoint.stream_body_out())
  let server = ep.serve_public(_ => Ok((None, @model.Bytes(b"payload"))))
  let client = @client.Client::new(
    @client.from_fn((request, _) => {
      server.dispatch(request, {}, @endpoint.DispatchContext::new())
    }),
    @fake.FakeClock::new(),
  )
  defer client.close()
  @driver.run_sync(() => {
    let result = ep.call(client, (), ()).unwrap().unwrap()
    assert_eq(result.0, None)
    assert_eq(result.1, Bytes(b"payload"))
  })
}

///|
test "retry snapshots survive later body acquisition and closure" {
  let source = @sim.Feed::new(@driver.Driver::new(), [Chunk(b"payload"), End])
  let stream = @http.StreamBody::new(source)
  let request = { ..@http.Request::post("/"), body: @http.Stream(stream), }
  let snapshot = @client.RetryContext::capture(request)
  assert_true(snapshot.replayable)
  ignore(stream.take())
  stream.close()
  assert_true(snapshot.replayable)
  assert_false(@client.RetryContext::capture(request).replayable)
  assert_eq(snapshot.request, request.head())
}

///|
test "retry snapshots survive later body acquisition and closure" {
  let source = @feed.Feed::new(@driver.Driver::new(), [Chunk(b"payload"), End])
  let stream = @model.StreamBody::new(source)
  let request = { ..@model.Request::post("/"), body: @model.Stream(stream), }
  let snapshot = @client.RetryContext::capture(request)
  assert_true(snapshot.replayable)
  ignore(stream.take())
  stream.close()
  assert_true(snapshot.replayable)
  assert_false(@client.RetryContext::capture(request).replayable)
  assert_eq(snapshot.request, request.head())
}

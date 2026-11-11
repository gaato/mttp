///|
test "endpoint SSE overflow behind a delivered event raises before another read" {
  let d = @driver.Driver::new()
  let limit = 16 * 1024 * 1024
  let source = @sim.Feed::new(d, [
    Chunk(b"data: 1\n\ndata: " + Bytes::make(limit + 1, b'x')),
    Wait(1_000_000),
    End,
  ])
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @mttp.Response::new(
        200,
        headers=@mttp.Headers::of([("content-type", "text/event-stream")]),
        body=Stream(@mttp.StreamBody::new(source)),
      )
    }),
    @sim.SimClock::new(d),
  )
  defer client.close()
  let ep = @endpoint.endpoint.get("/").output(@endpoint.sse_out(@schema.jint))
  let events = []
  let failure = try {
    ignore(
      d.run(() => {
        ep.call_with(client, (), (), stream => {
          stream.each(event => events.push(event))
        })
      }),
    )
    None
  } catch {
    @mttp.TransportError(kind~, phase~, ..) => Some((kind, phase))
    error => raise error
  }
  assert_eq(failure, Some((TooLarge(limit~), Body)))
  assert_eq(events, [1])
  assert_eq(source.reads(), 1)
  assert_eq(d.now(), 0L)
  assert_eq(source.closes(), 1)
}

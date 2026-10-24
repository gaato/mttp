///|
suberror UserStop {
  UserStop(String)
} derive(Debug)

///|
test "openai: streaming 429 head retried inside the attempt, body read once, [DONE] stops" {
  let stub = @testing.Stub::new([
    (429, [], ["{\"error\":\"slow down\"}"]),
    (
      200,
      [("content-type", "text/event-stream")],
      ["data: a\n\nda", "ta: b\n\n", "data: [DONE]\n\ndata: never\n\n"],
    ),
  ])
  let clock = @testing.FakeClock::new()
  let ai = @openai_stream.OpenAI::new(stub.backend(), clock)
  let seen = []
  @testing.run_sync(() => ai.stream_chat(async fn(d) { seen.push(d) }))
  assert_eq(seen, ["a", "b"])
  assert_eq(clock.slept, [500])
  assert_eq(stub.sent.length(), 2)
  assert_eq(stub.closed.val, 2)
}

///|
test "openai: user callback error propagates verbatim, stream closed" {
  let stub = @testing.Stub::new([(200, [], ["data: x\n\n", "data: y\n\n"])])
  let ai = @openai_stream.OpenAI::new(stub.backend(), @testing.FakeClock::new())
  let r = try {
    @testing.run_sync(() => {
      ai.stream_chat(async fn(d) { raise UserStop(d) })
    })
  } catch {
    e => Err(e)
  } noraise {
    _ => Ok(())
  }
  assert_true(r is Err(UserStop("x")))
  assert_eq(stub.closed.val, 1)
}

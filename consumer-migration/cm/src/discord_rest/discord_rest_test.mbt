///|
test "discord: 429 body retry_after drives the wait; telemetry reads body from Attempt.error" {
  let stub = @testing.Stub::new([
    (
      429,
      [("content-type", "application/json"), ("x-ratelimit-scope", "user")],
      ["{\"retry_after\": 0.25, \"global\": false}"],
    ),
    (200, [], ["{\"url\": \"wss://x\"}"]),
  ])
  let clock = @testing.FakeClock::new()
  let client = @discord_rest.Client::new("tok", stub.backend(), clock)
  let got = @testing.run_sync(() => client.request("/gateway", "gateway"))
  assert_true(got is { "url": "wss://x", .. })
  assert_eq(clock.slept, [251])
  assert_eq(client.telemetry, [
    HttpRequest(bucket="gateway", status=429, retries=0),
    HttpRateLimited(bucket="gateway", retry_after_ms=250L, global=false),
    HttpRequest(bucket="gateway", status=200, retries=1),
  ])
  // base_url resolution + template header reached the wire
  assert_eq(stub.sent[0].url.to_string(), "https://discord.com/api/v10/gateway")
  assert_eq(stub.sent[0].headers.get("authorization"), Some("Bot tok"))
  assert_eq(stub.closed.val, 2)
}

///|
test "discord: POST 500 not resent unless replay-safe attribute is set" {
  let stub = @testing.Stub::new([(500, [], ["{\"code\":0}"])])
  let clock = @testing.FakeClock::new()
  let client = @discord_rest.Client::new("tok", stub.backend(), clock)
  let r = try {
    @testing.run_sync(() => client.request("/channels/1/messages", "m", post={}))
  } catch {
    e => Err(e)
  } noraise {
    _ => Ok(())
  }
  assert_true(r is Err(@discord_rest.Api(status=500, ..)))
  assert_eq(clock.slept, [])
  let stub2 = @testing.Stub::new([(500, [], ["{}"]), (200, [], ["{\"id\":\"9\"}"])])
  let clock2 = @testing.FakeClock::new()
  let client2 = @discord_rest.Client::new("tok", stub2.backend(), clock2)
  let got = @testing.run_sync(() => {
    client2.request("/channels/1/messages", "m", post={}, replay_safe_call=true)
  })
  assert_true(got is { "id": "9", .. })
  assert_eq(clock2.slept, [500])
  // the replay-safe mark never reached the wire (it is an attribute, not a header)
  assert_eq(stub2.sent[0].headers.get("x-discord-mbt-replay-safe"), None)
}

///|
test "discord: exhausted 429 surfaces RateLimited; closed client is Pool/Closed" {
  let limited = (
    429,
    [("content-type", "application/json")],
    ["{\"retry_after\": 1.5}"],
  )
  let stub = @testing.Stub::new([limited, limited])
  let clock = @testing.FakeClock::new()
  let client = @discord_rest.Client::new("tok", stub.backend(), clock, max_retries=1)
  let r = try {
    @testing.run_sync(() => client.request("/x", "x"))
  } catch {
    e => Err(e)
  } noraise {
    _ => Ok(())
  }
  assert_true(r is Err(@discord_rest.RateLimited(retry_after_ms=1500L, global=false)))
  client.close()
  let r2 = try {
    @testing.run_sync(() => client.request("/x", "x"))
  } catch {
    e => Err(e)
  } noraise {
    _ => Ok(())
  }
  assert_true(r2 is Err(@discord_rest.Transport(phase=Pool, ..)))
}

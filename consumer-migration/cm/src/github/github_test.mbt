///|
test "github: generated request + paginator[T, Error] + Link next" {
  let stub = @testing.Stub::new([
    (
      200,
      [("link", "<https://api.github.com/repos/o/r/issues?page=2>; rel=\"next\"")],
      ["[{\"number\":1}]"],
    ),
    (200, [], ["[{\"number\":2}]"]),
  ])
  let clock = @testing.FakeClock::new()
  let gh = @github.GitHub::new(stub.backend(), clock)
  let pager : @client.Paginator[@gen.Issue, Error] = gh.paginator(
    @gen.issues_list_request("o", "r"),
    @gen.issues_list_decode,
  )
  let all = @testing.run_sync(() => pager.collect())
  assert_eq(all, [{ number: 1 }, { number: 2 }])
  assert_eq(
    stub.sent.map(r => r.url.to_string()),
    [
      "https://api.github.com/repos/o/r/issues", "https://api.github.com/repos/o/r/issues?page=2",
    ],
  )
  assert_eq(stub.sent[0].headers.get("accept"), Some("application/vnd.github+json"))
}

///|
test "github: GHE base path is lost if base_url means RFC 3986 resolution" {
  let stub = @testing.Stub::new([(200, [], ["[]"])])
  let gh = @github.GitHub::new(
    stub.backend(),
    @testing.FakeClock::new(),
    base_url="https://ghe.example.com/api/v3",
  )
  let _ = @testing.run_sync(() => {
    gh.call(@gen.issues_list_request("o", "r"), @gen.issues_list_decode)
  })
  // prototype resolve = prefix join (sdk-runtime semantics); see urlres/ for
  // what gaato/http's RFC resolver produces instead.
  assert_eq(stub.sent[0].url.to_string(), "https://ghe.example.com/api/v3/repos/o/r/issues")
}

///|
test "github: 403 secondary limit retried with as_bytes(); with _always it is a Deserialization, not retried" {
  let limited = (403, [("retry-after", "2")], ["{\"message\":\"You have exceeded a secondary rate limit\"}"])
  let stub = @testing.Stub::new([limited, (200, [], ["[]"])])
  let clock = @testing.FakeClock::new()
  let gh = @github.GitHub::new(stub.backend(), clock)
  let got = @testing.run_sync(() => {
    gh.call(@gen.issues_list_request("o", "r"), @gen.issues_list_decode)
  })
  assert_eq(got, [])
  assert_eq(clock.slept, [2000])
  let stub2 = @testing.Stub::new([limited, (200, [], ["[]"])])
  let clock2 = @testing.FakeClock::new()
  let gh2 = @github.GitHub::new(stub2.backend(), clock2)
  let r = try {
    @testing.run_sync(() => {
      gh2.call(@gen.issues_list_request("o", "r"), @gen.issues_list_decode, always=true)
    })
  } catch {
    e => Err(e)
  } noraise {
    _ => Ok(())
  }
  assert_true(r is Err(@client.Deserialization({ status: 403, .. }, ..)))
  assert_eq(clock2.slept, [])
}

///|
test "github: GraphQL RATE_LIMITED in a 200 is retried by the decider" {
  let stub = @testing.Stub::new([
    (200, [], ["{\"errors\":[{\"type\":\"RATE_LIMITED\",\"message\":\"x\"}]}"]),
    (200, [], ["{\"data\":{\"viewer\":{\"login\":\"g\"}}}"]),
  ])
  let clock = @testing.FakeClock::new()
  let gh = @github.GitHub::new(stub.backend(), clock)
  let j = @testing.run_sync(() => gh.graphql("{ viewer { login } }"))
  assert_true(j is { "data": { "viewer": { "login": "g", .. }, .. }, .. })
  assert_eq(clock.slept, [1000])
}

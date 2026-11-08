# gaato/mttp/client

The HTTP client of gaato/mttp: a description of what to send and how to read
the answer, and a `Client` that sends it through any `@http.Backend` with
defaults, admission, deadlines, decoded-body limits and retries. It does no
I/O itself; `gaato/http-async` provides the backends that do, and
`gaato/mttp/testing` the stubs.

## Requests and response plans

A `RequestPlan[T, M]` pairs an `@http.Request` with a `ResponsePlan[T, M]`,
which says how to turn the response into a `T`. The mode `M` says when the
body is read:

- `Buffered` plans are read inside the attempt, so a rejected status or an
  undecodable body reaches the retry decision: `as_bytes`, `as_string`,
  `as_json`, `as_json_value`, `as_form`, `ignore_body`, `ResponsePlan::new`,
  `ResponsePlan::reject` and `as_both`.
- `Streaming` plans hand the body to a callback after the attempt, and that
  callback is never retried: `as_stream`, `as_sse`, `as_lines` and
  `ResponsePlan::stream`.
- `from_head` chooses a plan once the head is known; `as_streaming` widens a
  Buffered plan, never the reverse.

Expected failures are values. The built-in readers return
`Result[_, ResponseFailure]`: `UnexpectedStatus` for a rejected status and
`Deserialization` for a body that does not decode, each with the real head
and at most 1 MiB of the body. A `TransportError`, a cancellation and any
other error stay raised, with their identity.

## The client loop

`Client::send` (or `RequestPlan::send`) is the only sending path. It joins the
`base_url`, merges default headers under the request's own, then for each
attempt acquires the `RateLimiter`, builds the body (`body_fn` runs after
admission, so a retry gets fresh bytes), sends, releases the limiter with the
head it got, reports one `Attempt` to the observer and asks the
`RetryPolicy`, or a typed `decide_retry` that also sees the policy's
default. Retrying is opt-in (`RetryPolicy::none()` is the default), a stream
body is never resent without a body factory, and idempotency comes from the
method or the `replay_safe` attribute.

Each attempt maps the plan onto the `@http.SendOptions` the backend gets:

| Plan | `body` | The Client's reader |
|---|---|---|
| Buffered | `Exchange(max_bytes = max_body_bytes)`: the deadline covers the body, and the backend admits at most that many wire bytes | keeps at most `max_body_bytes` decoded bytes |
| Streaming, `from_head` included | `Stream(idle_ms = read_idle_ms)`: the deadline ends at the head, each read gets the idle limit | a buffered branch the head selects keeps `max_body_bytes` and the rest of the attempt deadline, enforced with the Client's Timer |

`timeout_ms`, `max_body_bytes` and `read_idle_ms` are Client defaults that a
plan overrides field by field. `total_ms` bounds the whole call, admission,
retry waits and the stream consumer included; it requires a Timer.

```mbt check
///|
test "retry a 503 and read JSON" {
  // A backend that is busy once, then answers.
  let mut calls = 0
  let backend = @client.from_fn((_, _) => {
    calls += 1
    if calls == 1 {
      @http.Response::new(503)
    } else {
      @http.Response::new(200, body=Bytes(b"{\"id\":7}"))
    }
  })
  let client = @client.Client::new(
    backend,
    @sim.FakeClock::new(),
    base_url="https://api.example/v1",
    retry=@client.RetryPolicy::conservative(),
  )
  let plan : @client.ClientRequest[Result[Json, @client.ResponseFailure]] = @client.get(
    "/items/7",
  ).response(@client.as_json_value())
  let reply = @driver.run_sync(() => client.send(plan))
  assert_eq(reply.body, Ok({ "id": 7 }))
  assert_eq(reply.request.url, "https://api.example/v1/items/7")
  assert_eq(calls, 2)
}
```

## Wrappers

A policy that needs only the request and the response head is a Backend
wrapper:

- `FollowRedirects` follows 301, 302, 303, 307 and 308 under a
  `RedirectConfig` (10 hops, no HTTPS downgrade, credentials removed on an
  origin change), overridden per request by the `redirect_limit` attribute
  that `RequestPlan::follow_redirects` and `max_redirects` set. It records
  `redirect_history` and `final_url`. Keep retries above it; a transport
  failure on a later hop never reads as unsent, since the first request was
  answered.
- `from_fn` and `from_handler` turn a function or an `@http.Handler` into a
  backend that validates what it is given.

## Helpers

`Paginator` walks cursor-paged APIs with failures as values; `parse_link_next`
reads an RFC 8288 `Link: <…>; rel="next"`; `parse_retry_after` and
`retry_after_ms` read server-requested delays; `RequestPlan::to_curl` renders
a request for diagnostics with credentials redacted.

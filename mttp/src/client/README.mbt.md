# gaato/mttp/client

The HTTP client: request and response plans, and a `Client` that sends them.

A plan describes what to send and how to read the answer; the `Client` sends
it through any `@mttp.Backend` with defaults, admission, deadlines,
decoded-body limits, redirects, cookies and retries. It does no I/O itself: `gaato/mttp_async`
provides the backends that do, and `gaato/mttp/testing` the stubs.

## Requests and response plans

A `RequestPlan[T, M]` pairs an `@mttp.Request` with a `ResponsePlan[T, M]`,
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
admission, so a retry gets fresh bytes), sends, releases the limiter with that
acquire's `Admission` and the head it got, reports one `Attempt` to the
observer and asks the `RetryPolicy`, or a typed `decide_retry` that also
sees the policy's default. Retrying is opt-in (`RetryPolicy::none()` is the
default), a stream body is never resent without a body factory, and
idempotency comes from the method or the `replay_safe` attribute. Without a
`limiter`, admission is immediate; `gaato/mttp/client/ratelimit` has one that
follows a server's quota headers, and the rules for writing your own.

`Client::close()` records closure and closes the shared backend idempotently.
If an observer closes the client after a retry decision, the loop returns
the last attempt's reply or raised error without sleeping or acquiring again.
Closure during backoff takes effect when the injected clock's sleep wakes;
it returns that same outcome without another acquire or attempt. An accepted
stream is still handed to its consumer as with `Stop`. The completed attempt
keeps its paired release. Sends begun after closure fail with `Closed` in
phase Pool before admission.

Each attempt maps the plan onto the `@mttp.SendOptions` the backend gets:

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
      @mttp.Response::new(503)
    } else {
      @mttp.Response::new(200, body=Bytes(b"{\"id\":7}"))
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

## Redirects and cookies

A Client follows 301, 302, 303, 307 and 308 over whatever backend it is
given, a test function included, under its `redirect` argument
(`RedirectConfig::default()`: 10 hops, no HTTPS downgrade, credentials
removed on an origin change). A request overrides the limit with
`RequestPlan::follow_redirects(false)` or `max_redirects(n)`, and the reply's
attributes carry `redirect_history` and `final_url`. The hops of one
attempt share its admission and its deadline, and a retry starts again from
the original request: a 503 on the second hop resends the first. A transport
failure on a later hop never reads as unsent, since the first request was
answered.

`redirect=RedirectConfig::none()` turns redirects off for the whole Client:
every 3xx comes back as the backend gave it.

With `cookies=`, a caller-owned `@cookie.CookieJar`, the Client sends the
jar's matching cookies with every request and redirect hop and stores every
response's `Set-Cookie` before the next hop. Several Clients may share a jar.

```mbt check
///|
test "a login that answers with a redirect and a cookie" {
  let backend = @client.from_fn((request, _) => {
    if request.url.has_suffix("/login") {
      @mttp.Response::new(
        302,
        headers=@mttp.Headers::of([
          ("location", "/home"),
          ("set-cookie", "session=abc; Path=/"),
        ]),
      )
    } else {
      @mttp.Response::new(
        200,
        body=Bytes(@utf8.encode(request.headers.get("cookie").unwrap_or(""))),
      )
    }
  })
  let jar = @cookie.CookieJar::new(@sim.FakeClock::new())
  let client = @client.Client::new(
    backend,
    @sim.FakeClock::new(),
    base_url="https://shop.example",
    cookies=jar,
  )
  let reply = @driver.run_sync(() => client.send(@client.get("/login")))
  assert_eq(reply.body, Ok("session=abc"))
  assert_eq(
    reply.attributes.get(@client.final_url),
    Some("https://shop.example/home"),
  )
}
```

## Wrappers

A policy that needs only the request and the response head is a Backend
wrapper:

- `FollowRedirects` and `Cookies` (in `gaato/mttp/client/cookies`) are what
  the Client wraps its backend in, as `FollowRedirects(Cookies(backend,
  jar))`. Use them directly to build a stack of your own, for example to put
  another wrapper between them, and give the Client over that stack
  `redirect=RedirectConfig::none()` so redirects are not followed twice; the
  per-request limit then reaches the stack's own `FollowRedirects`.
- `from_fn` and `from_handler` turn a function or an `@mttp.Handler` into a
  backend that validates what it is given.

## Helpers

`Paginator` walks cursor-paged APIs with failures as values; `parse_link_next`
reads an RFC 8288 `Link: <…>; rel="next"`; `parse_retry_after` and
`retry_after_ms` read server-requested delays; `RequestPlan::to_curl` renders
a request for diagnostics with credentials redacted.

`ResponsePlan::prepared_stream(decode, use_)` joins the two modes: `decode`
bounds and decodes the body inside the attempt, so its `Err` reaches the retry
decision, and `use_` receives the decoded value once, after the retry
decisions, as a streaming callback would. The typed endpoint client uses it
for buffered outputs read with `call_with`.

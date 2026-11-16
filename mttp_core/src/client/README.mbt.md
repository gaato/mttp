# gaato/mttp_core/client

The HTTP client: request and response plans, and a `Client` that sends them.

A plan describes what to send and how to read the answer; the `Client` sends
it through any `@mttp_core.Backend` with defaults, admission, deadlines,
decoded-body limits, redirects, cookies and retries. It does no I/O itself: `gaato/mttp`
provides the backends that do, and `gaato/mttp_core/testing` the stubs.

## Requests and response plans

A `RequestPlan[T, M]` pairs an `@mttp_core.Request` with a `ResponsePlan[T, M]`,
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
`limiter`, admission is immediate; `gaato/mttp_core/client/ratelimit` has one that
follows a server's quota headers, and the rules for writing your own.

`Client::close()` records closure and closes the shared backend idempotently.
If an observer closes the client after a retry decision, the loop returns
the last attempt's reply or raised error without sleeping or acquiring again.
Closure during backoff takes effect when the injected clock's sleep wakes;
it returns that same outcome without another acquire or attempt. An accepted
stream is still handed to its consumer as with `Stop`. The completed attempt
keeps its paired release. Sends begun after closure fail with `Closed` in
phase Pool before admission.

Each attempt maps the plan onto the `@mttp_core.SendOptions` the backend gets:

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
      @mttp_core.Response::new(503)
    } else {
      @mttp_core.Response::new(200, body=Bytes(b"{\"id\":7}"))
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
      @mttp_core.Response::new(
        302,
        headers=@mttp_core.Headers::of([
          ("location", "/home"),
          ("set-cookie", "session=abc; Path=/"),
        ]),
      )
    } else {
      @mttp_core.Response::new(
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

## Observability

`events=` (opt-in, beside the `observer`) receives every `ClientEvent` of every
send, inline and in order. For each attempt it gets `AttemptStart`, then the
backend's `Phase` events and a `Redirect` for each hop followed inside the
attempt, then `AttemptEnd` with the `Attempt` the observer gets. A `Retry`
comes between one attempt's end and the next one's start, when the retry is
admitted, immediately before `AttemptStart`; a retry stopped by closing,
budget exhaustion, cancellation, a total deadline or failure during limiter
acquisition reports none. Nothing about an attempt follows its `AttemptEnd`, a cancelled
one included: a late phase report from the backend is dropped.

`Phase` events come from the backend through the `@mttp_core.on_phase`
request attribute, which the Client sets on each attempt. A backend reports
what it can see, in this order and at most once per exchange: `Dialed(addr)`,
`TlsDone`, `Pooled(reused)`, `Written`, `FirstByte`. The HTTP/1.1 engine
(`gaato/mttp_core/h1client`) reports them all; a connection taken from the
pool reports `Pooled(reused=true)` without `Dialed` or `TlsDone`. JS fetch
cannot see connections or TLS and reports none. Each redirect hop is its own
exchange, so the phases start again after each `Redirect`.

Every event has an Int64 `send_id`, increasing from 1 and unique within that
`Client`, preserved across all attempts and redirect hops of one `send`.
Concurrent sends can therefore be grouped by `(Client, send_id)`; the
`observer` still receives the unchanged `Attempt`. Exhausting Int64 refuses
further sends with `Invalid` in phase Pool before admission instead of reusing
an identifier.

The fields are named so that an OpenTelemetry exporter, built in a module of
its own, maps them onto the HTTP client semantic conventions directly:

| Event field | OpenTelemetry attribute |
|---|---|
| every event's `send_id` | exporter correlation key for one logical send's parent span; `(send_id, attempt)` identifies its attempt child spans, and phases/redirects attach to the active child; local to a Client, not a trace/span id |
| `AttemptStart.request.meth` | `http.request.method` |
| `AttemptStart.request.url` | `url.full` (redact it first if it carries secrets) |
| `AttemptStart.attempt`, `Retry.attempt` | `http.request.resend_count` |
| `AttemptStart.request.headers`, `Attempt.headers` | `http.request.header.<name>`, `http.response.header.<name>` (pass them through `redact_headers`) |
| `Attempt.status`, `Redirect.status` | `http.response.status_code` (0: no response) |
| `Attempt.duration_ms` | the `http.client.request.duration` histogram, in seconds |
| `Attempt.error`, `Retry.reason` | `error.type`: the status code, or the transport failure's kind (`timeout`, `connect`, ...) |
| `Phase(Dialed(addr))` | `server.address` and `server.port` of the connection (the proxy when one is used) |
| `Phase(Pooled(reused))` | connection reuse; span events `Dialed` to `FirstByte` give the connect, TLS and time-to-first-byte timings |
| `trace_id` (with `trace_context`) | the span's trace id |

`trace_context(backend, generate=random)` is a Backend wrapper that gives each
request without one a W3C `traceparent` (version 00, random trace and span ids
from the injected source, sampled) and records the trace id on the response
under `trace_id`; a request that has its own `traceparent` keeps it.

`redact_headers(headers)` replaces the values of credential fields with
`<redacted>` for logging; its default list, `default_sensitive_headers`, is
the one `to_curl` uses, plus `set-cookie`.

```mbt check
///|
test "log each attempt with its phases, credentials hidden" {
  let backend = @client.from_fn((request, _) => {
    if request.attributes.get(@mttp_core.on_phase) is Some(report) {
      report(Written)
      report(FirstByte)
    }
    @mttp_core.Response::new(200)
  })
  let log = []
  let client = @client.Client::new(
    @client.trace_context(backend, generate=() => 0.5),
    @sim.FakeClock::new(),
    headers=@mttp_core.Headers::of([("authorization", "Bearer secret")]),
    events=event => {
      match event {
        AttemptStart(request~, ..) => {
          let headers = @client.redact_headers(request.headers)
          log.push("start \{headers.get("authorization").unwrap_or("")}")
        }
        Phase(phase=Written, ..) => log.push("written")
        Phase(phase=FirstByte, ..) => log.push("first byte")
        AttemptEnd(attempt, ..) => log.push("end \{attempt.status}")
        _ => ()
      }
    },
  )
  let reply = @driver.run_sync(() => {
    client.send(@client.get("https://api.example/"))
  })
  assert_eq(log, ["start <redacted>", "written", "first byte", "end 200"])
  assert_eq(
    reply.attributes.get(@client.trace_id),
    Some("80000000800000008000000080000000"),
  )
}
```

## Wrappers

A policy that needs only the request and the response head is a Backend
wrapper:

- `FollowRedirects` and `Cookies` (in `gaato/mttp_core/client/cookies`) are what
  the Client wraps its backend in, as `FollowRedirects(Cookies(backend,
  jar))`. Use them directly to build a stack of your own, for example to put
  another wrapper between them, and give the Client over that stack
  `redirect=RedirectConfig::none()` so redirects are not followed twice; the
  per-request limit then reaches the stack's own `FollowRedirects`.
- `from_fn` and `from_handler` turn a function or an `@mttp_core.Handler` into a
  backend that validates what it is given.
- `trace_context` adds a W3C `traceparent` to each request that has none
  (see Observability).

## Resilience

Three opt-in pieces keep a long-running client working while servers come
and go. None changes what a `Client` does unless it is used.

### Reconnecting streams

`ReconnectPolicy` says when to reconnect a stream that ended, as data:
`decide(attempts~, lived_ms~, server_hint_ms?, random~)` returns `Wait(ms)`
or `GiveUp`, and `next_attempts` gives the count for the next call.
`ReconnectPolicy::default()` waits from 1 s doubling to 30 s, each wait
spread over its upper half, never gives up, starts the count again after a
connection that lived 60 s, and honours a server's requested wait within
the cap.

`Client::sse_reconnecting(request, receive, policy~, stop~)` runs the
`EventSource` loop with it: it reads each event-stream connection with
`@sse.SseReader`, and when one ends or fails it waits per the policy (the
stream's `retry:` field, or a 408, 429 or 5xx response's `Retry-After`, is
the server's hint) and sends the request again with `Last-Event-ID` set to
the stream's last event ID. A 204 stops it, as does a status that sending
again cannot fix or a 200 that is not `text/event-stream`; it returns how it
ended as an `SseEnd`. A failure that would recur at once (`TooLarge` for an
oversized event, `Invalid`, `Closed`), an error from `receive` and
cancellation are raised.

```mbt check
///|
test "an event stream that ends, resumes from its last id and is told to stop" {
  let ids = []
  let backend = @client.from_fn((request, _) => {
    ids.push(request.headers.get("last-event-id"))
    if ids.length() == 1 {
      @mttp_core.Response::new(
        200,
        headers=@mttp_core.Headers::of([("content-type", "text/event-stream")]),
        body=Bytes(b"retry: 250\nid: 7\ndata: hello\n\n"),
      )
    } else {
      @mttp_core.Response::new(204)
    }
  })
  let clock = @sim.FakeClock::new()
  let client = @client.Client::new(backend, clock)
  let received = []
  let end = @driver.run_sync(() => {
    client.sse_reconnecting(@mttp_core.Request::get("https://h.example/feed"), event => {
      received.push(event.data)
    })
  })
  assert_true(end is NoContent)
  assert_eq(received, ["hello"])
  assert_eq(ids, [None, Some("7")])
  assert_eq(clock.slept(), [250])
}
```

A WebSocket application owns its loop, because only it knows what to resend
after reconnecting; the policy is the same. With `gaato/mttp`'s `@ws.connect`:

```mbt nocheck
///|
async fn follow(url : String, clock : &@rt.Clock) -> Unit {
  let policy = @client.ReconnectPolicy::default()
  for attempts = 0 {
    let mut opened : Int64? = None
    try {
      let session = @ws.connect(url)
      opened = Some(clock.now_unix_ms())
      for ;; {
        handle(session.recv()) // the application's own work
      }
    } catch {
      _ => () // failed or closed: decide whether to reconnect
    }
    let lived_ms = match opened {
      Some(at) => clock.now_unix_ms() - at
      None => 0L
    }
    match policy.decide(attempts~, lived_ms~, random=@rt.default_random()) {
      Wait(ms) => clock.sleep(ms)
      _ => return // GiveUp
    }
    continue policy.next_attempts(attempts~, lived_ms~)
  }
}
```

### Circuit breaker

`CircuitBreaker::new(backend, clock~)` keeps one circuit per origin. When at
least `failure_ratio` (10 %) of at least `min_requests` (100) requests in a
`window_ms` (30 s) window failed (a transport failure other than `Invalid`,
or a 502, 503 or 504; never a 4xx), the circuit opens: for `open_ms` (5 s)
requests fail at once with `TransportError(kind=CircuitOpen, phase=Pool)`,
unsent, which the retry rules never retry. Then `half_open_probes` (1)
requests go through: a success closes the circuit, a failure opens it again.
At most `max_origins` (1024) circuits are kept, the least recently used
evicted first. Give it to `Client::new` as the backend, so each redirect hop
and each retry is counted.

```mbt check
///|
test "a failing origin is cut off and probed again" {
  let mut calls = 0
  let clock = @sim.FakeClock::new()
  let breaker = @client.CircuitBreaker::new(
    @client.from_fn((_, _) => {
      calls += 1
      @mttp_core.Response::new(if calls == 1 { 503 } else { 200 })
    }),
    clock~,
    min_requests=1,
  )
  let client = @client.Client::new(breaker, clock)
  let get = () => {
    @driver.run_sync(() => client.send(@client.get("https://h.example/")).status) catch {
      @mttp_core.TransportError(kind=CircuitOpen, ..) => 0
      error => abort(error.to_string())
    }
  }
  assert_eq(get(), 503)
  assert_eq(get(), 0) // open: refused without sending
  clock.advance(5000)
  assert_eq(get(), 200) // the probe succeeded: closed again
  assert_eq(calls, 2)
}
```

### Refreshing credentials

`AuthRefresh::new(backend, origin~, refresh~, apply~, coordination~)` puts the
current credentials on requests to the explicitly bound absolute HTTP(S)
`origin` with `apply`. Scheme, host and effective port must all match; a
same-host HTTP-to-HTTPS upgrade is a different origin too. Other requests
pass through untouched, without `apply` or refresh, so `Client`'s redirect
layer cannot reapply these credentials to a different origin. Bind one
wrapper per credential origin; `apply` should only set credentials, keeping
the request URL unchanged. When a matching request gets a 401, it calls the
async `refresh` once, shared by every 401 that arrives meanwhile (they wait on
an `@rt.Signal` from `coordination`), and sends the request once more,
marked with `auth_refreshed` so it is never refreshed again. A stream body
that was already sent returns its original 401 without refreshing. Before
starting or joining a refresh, the 401 transport is closed, releasing the
pool slot even with `max_connections=1`; `refresh` may therefore use that
same HTTP client. If refresh raises, the original 401 status, headers and
attributes are returned with an empty body. Closing instead of buffering
keeps this independent of the size or speed of an untrusted 401 body.

```mbt check
///|
test "an expired token is refreshed once and the request resent" {
  let token = Ref("old")
  let seen = []
  let d = @driver.Driver::new()
  let backend = @client.AuthRefresh::new(
    @client.from_fn((request, _) => {
      let auth = request.headers.get("authorization").unwrap_or("")
      seen.push(auth)
      @mttp_core.Response::new(if auth == "Bearer new" { 200 } else { 401 })
    }),
    origin=@mttp_core.Url::parse("https://api.example/"),
    refresh=() => token.val = "new",
    apply=request => request.bearer(token.val),
    coordination=@sim.SimCoordination::new(d),
  )
  let client = @client.Client::new(backend, @sim.SimClock::new(d))
  let reply = d.run(() => client.send(@client.get("https://api.example/me")))
  assert_eq(reply.status, 200)
  assert_eq(seen, ["Bearer old", "Bearer new"])
}
```

## Helpers

`Paginator` walks cursor-paged APIs with failures as values; `parse_link_next`
reads an RFC 8288 `Link: <…>; rel="next"`; `parse_retry_after` and
`retry_after_ms` read server-requested delays; `RequestPlan::to_curl` renders
a request for diagnostics with credentials redacted, and `redact_headers`
does the same to a header list for logging.

`ResponsePlan::prepared_stream(decode, use_)` joins the two modes: `decode`
bounds and decodes the body inside the attempt, so its `Err` reaches the retry
decision, and `use_` receives the decoded value once, after the retry
decisions, as a streaming callback would. The typed endpoint client uses it
for buffered outputs read with `call_with`.

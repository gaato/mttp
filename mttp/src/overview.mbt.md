# gaato/mttp

HTTP for [MoonBit](https://www.moonbitlang.com/) without I/O: the types,
an HTTP/1.1 codec and connection engines, a client with retries under a
budget, deadlines, rate limits, redirects and cookies, server-sent events and
multipart bodies, and typed endpoints with a router and OpenAPI documents.
It depends on `moonbitlang/core` alone and builds on wasm-gc, wasm, js and
native, with the same tests on each.

Building an app? Add [`gaato/mttp_async`](https://mooncakes.io/docs/gaato/mttp_async)
instead: it sends requests over the network with sensible defaults and
re-exports what an app uses from here. Libraries, such as an SDK for some
API, depend on this module, so the app decides how requests are sent and
tests run without a network.

The design follows the split of Scala's [sttp](https://sttp.softwaremill.com/)
family: a model, a client over swappable backends, and endpoint descriptions
interpreted as a server, a client and documentation.

## Install

```sh
moon add gaato/mttp
```

## Requests and backends

Values are immutable: each builder returns a copy.

```mbt check
///|
test "describe a request" {
  let request = @mttp.Request::post("https://api.example.com/v1/items")
    .query("dry_run", "true")
    .bearer("token")
    .body_json({ "name": "first" })
  assert_eq(request.url, "https://api.example.com/v1/items?dry_run=true")
  assert_eq(request.headers.get("content-type"), Some("application/json"))
  assert_false(@mttp.is_idempotent(request))
}
```

A `Backend` sends one exchange and returns the response. Every failure is a
`TransportError` whose phase says how far the exchange got, so `is_unsent`
tells whether resending a non-idempotent request is safe.
`gaato/mttp_async` provides the backend for `moonbitlang/core/async`; another
runtime implements `Backend` itself, or only the ports in `rt` and reuses the
`h1client` engine.

## A client in a library

A library takes a `Client` and leaves the backend to its caller. In a test,
the backend is a function:

```mbt check
///|
/// Reads an item's name from a JSON API.
async fn item_name(client : @client.Client, id : Int32) -> String? {
  let reply = client.send(
    @client.get("/items/\{id}").response(@client.as_json_value()),
  )
  match reply.body {
    Ok({ "name": String(name), .. }) => Some(name)
    _ => None
  }
}

///|
test "a library call against a test backend" {
  let seen = Ref("")
  let backend = @client.from_fn((request, _) => {
    seen.val = request.url
    @mttp.Response::new(
      200,
      headers=@mttp.Headers::of([("content-type", "application/json")]),
      body=Bytes(b"{\"name\": \"lamp\"}"),
    )
  })
  let client = @client.Client::new(
    backend,
    @sim.FakeClock::new(),
    base_url="https://api.example.com",
  )
  assert_eq(@driver.run_sync(() => item_name(client, 7)), Some("lamp"))
  assert_eq(seen.val, "https://api.example.com/items/7")
}
```

`Client::new` sends nothing it is not told to: retries, deadlines and rate
limits are opt-in here (`retry=`, `timeout_ms=`, `limiter=`), while
`gaato/mttp_async`'s `client()` turns them on for apps.

## Typed endpoints

One definition gives a client call, a server handler behind a router and an
OpenAPI document:

```mbt check
///|
test "one definition for client, server and docs" {
  let hello = @endpoint.endpoint
    .get("/hello/{name}")
    .input(@endpoint.path("name", @schema.string))
    .output(@endpoint.text_out())
    .operation_id("hello")
  let router = @router.Router::new([
    hello.serve_public(name => Ok("hello, \{name}")),
  ])
  let client = @client.Client::new(router, @sim.FakeClock::new())
  @driver.run_sync(() => {
    let reply = hello.request((), "moon").send(client)
    assert_true(reply.body is Ok(Ok("hello, moon")))
  })
  let spec = @openapi.to_openapi(
    [hello.doc()],
    @apispec.Info::new("Hello", "1"),
  )
  assert_eq(@openapi.check_documented(spec, "/hello/{name}", Get, 200), None)
}
```

The router is itself a `Backend`, as above, and its `handler()` is what
`gaato/mttp_async`'s server or a JavaScript `fetch` export serves.

Requests and responses also carry `Attributes`: typed local metadata that is
never sent. A server shutting down lets running responses finish, and a
streamed response with `close_on_shutdown` set to true is closed instead of
being drained. It is for endless streams such as server-sent events, whose
clients reconnect; the endpoint layer's `sse_out` sets it.

## Packages

| Package | What it holds |
|---|---|
| `gaato/mttp` | The vocabulary: methods, headers, URLs, requests, responses and bodies, `Backend` and `SendOptions`, `TransportError`, URL, form and HTTP-date helpers |
| `gaato/mttp/client` | Request and response plans with Result-valued readers, the `Client` loop (defaults, admission, deadlines, decoded-body limits, retries and the `RetryBudget`), `FollowRedirects`, `Paginator`, Retry-After and `Link` helpers |
| `gaato/mttp/client/retry` | Retry rules and decisions as data |
| `gaato/mttp/client/ratelimit` | Bounded window state, pacing, global quotas and header-driven admission |
| `gaato/mttp/client/cookies` | A cookie-jar backend wrapper |
| `gaato/mttp/sse` | A bounded `text/event-stream` parser, reader and encoder |
| `gaato/mttp/multipart` | A `multipart/form-data` writer with streamed parts |
| `gaato/mttp/cookie` | An RFC 6265 cookie jar on an injected clock |
| `gaato/mttp/jsonkit` | `Presence`, an object builder, field decoders and open enums for JSON models |
| `gaato/mttp/schema` | Text, JSON and body codecs that carry their JSON Schema, and validators |
| `gaato/mttp/endpoint` | Typed endpoint inputs and outputs, client calls and bounded server dispatch |
| `gaato/mttp/router` | Path and method dispatch, server policy, middleware, CORS; also a `Backend` |
| `gaato/mttp/openapi` | OpenAPI documents projected from endpoints, reference checks and a docs endpoint |
| `gaato/mttp/apispec` | OpenAPI document records with their JSON codecs (3.1, and 3.2's fields) |
| `gaato/mttp/endpoint/testkit` | Typed endpoint stubs and the definition checker |
| `gaato/mttp/testing` | `BackendStub`, canned answers and fault injection for client tests |
| `gaato/mttp/h1` | The sans-IO HTTP/1.1 codec: bounded decoders, strict parsers that refuse request smuggling, wire writers |
| `gaato/mttp/h1client` | The HTTP/1.1 client engine over the `rt` ports: connection pool, bounded heads and bodies, phase deadlines, proxies |
| `gaato/mttp/h1server` | The HTTP/1.1 server engine over the `rt` ports for one accepted connection |
| `gaato/mttp/rt` | The ports a runtime provides: `Clock`, `Timer`, `Gate`, `Conn`, `Dialer`, `Signal`, `Coordination` |
| `gaato/mttp/sim` | In-memory doubles of the ports and the contract checks every implementation passes |
| `gaato/mttp/driver` | A deterministic task driver with virtual time and `run_sync` for plain tests (experimental: it relies on compiler intrinsics) |

## License

Apache-2.0

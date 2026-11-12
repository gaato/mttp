# gaato/mttp

HTTP for [MoonBit](https://www.moonbitlang.com/) without I/O: the types,
an HTTP/1.1 codec and connection engines, a client with retries under a
budget, deadlines, rate limits, redirects and cookies, server-sent events and
multipart bodies, and typed endpoints with a router and OpenAPI documents.
It depends on `moonbitlang/core` alone and builds on wasm-gc, wasm, js and
native, with the same tests on each.

Building an app? Start with [`gaato/mttp_async`](https://mooncakes.io/docs/gaato/mttp_async):
it sends requests over the network with sensible defaults and re-exports the
types and client functions an app uses most. Add `gaato/mttp` beside it for
the rest: typed endpoints, the router, OpenAPI documents, multipart bodies,
rate limits and test stubs. Libraries, such as an SDK for some API, depend on
this module alone, so the app decides how requests are sent and tests run
without a network.

Coming from `gaato/http` or `gaato/http-async`? They are now `gaato/mttp` and
`gaato/mttp_async`; the
[changelog](https://github.com/gaato/mttp/blob/main/mttp/CHANGELOG.md) says
what to rename.

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

### On another runtime

`gaato/mttp_async` provides the backends for `moonbitlang/core/async`, on
native, wasm and js (through the host's `fetch`); wasm-gc has no runtime
there. A program on wasm-gc or on another runtime uses this module directly:
implement `Backend` over that runtime's HTTP client, or implement only the
ports in `rt` and reuse the `h1client` engine, then pass the backend, a
`Clock` and, for deadlines, a `Timer` to `Client::new`. The client, typed
endpoints and server-sent events work unchanged. This is also how to use it
in an app whose framework still runs on the registry module
`moonbitlang/async`, which cannot share a program with
`moonbitlang/core/async`.

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

`gaato/mttp/driver` is experimental, so a test package that calls
`@driver.run_sync` lists it in its `moon.pkg`:
`options("allow-experimental-packages": [ "gaato/mttp/driver" ])`.

`Client::new` sends nothing it is not told to: retries, deadlines and rate
limits are opt-in here (`retry=`, `timeout_ms=`, `limiter=`), while
`gaato/mttp_async`'s `client()` turns retries and deadlines on for apps.
Redirects are followed by default, over any backend, a test function
included (`redirect=` configures them, `RedirectConfig::none()` turns them
off), and cookies are kept when the Client is given a jar (`cookies=`). The
`gaato/mttp/client/ratelimit` section below shows a limiter that follows a
server's quota headers.

Every failure prints as a readable message: `"\{error}"` on a
`TransportError`, or `failure.to_string()` on a `ResponseFailure`, summarises
it (status, phase, cause) for logs and UIs.

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

## Packages

| Package | What it holds |
|---|---|
| `gaato/mttp` | The vocabulary: methods, headers, URLs, requests, responses and bodies, `Backend` and `SendOptions`, `TransportError`, URL, form and HTTP-date (parse and format) helpers |
| `gaato/mttp/client` | Request and response plans with Result-valued readers, the `Client` loop (defaults, admission, deadlines, decoded-body limits, redirects, cookies, retries and the `RetryBudget`), `FollowRedirects`, `Paginator`, Retry-After and `Link` helpers |
| `gaato/mttp/client/retry` | Retry rules and decisions as data |
| `gaato/mttp/client/ratelimit` | Bounded window state, pacing, global quotas and header-driven admission |
| `gaato/mttp/client/cookies` | `Cookies`, the cookie-jar backend wrapper a Client with `cookies=` uses, for stacks built by hand |
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

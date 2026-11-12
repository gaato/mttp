# gaato/mttp_core

HTTP for [MoonBit](https://www.moonbitlang.com/) without I/O: the types,
an HTTP/1.1 codec and connection engines, a client with retries under a
budget, deadlines, rate limits, redirects and cookies, server-sent events and
multipart bodies, and typed endpoints with a router and OpenAPI documents.
It depends on `moonbitlang/core` alone and builds on wasm-gc, wasm, js and
native, with the same tests on each.

Building an app? Start with [`gaato/mttp`](https://mooncakes.io/docs/gaato/mttp):
it sends requests over the network with sensible defaults and re-exports the
types, request attributes and client functions an app uses. Add
`gaato/mttp_core` beside it for the rest: typed endpoints, the router,
OpenAPI documents, multipart bodies, rate limits and test stubs. Libraries,
such as an SDK for some API, depend on this module alone, so the app
decides how requests are sent and tests run without a network.

Coming from `gaato/mttp` 0.2 or earlier? This is that module, renamed: from
0.3, `gaato/mttp` is the module an app adds (formerly `gaato/mttp_async`).
In a library, replace `gaato/mttp` with `gaato/mttp_core` in `moon.mod` and
`moon.pkg`, and `@mttp.` with `@mttp_core.` in code; the
[changelog](https://github.com/gaato/mttp/blob/main/mttp_core/CHANGELOG.md)
has the details. Coming from `gaato/http` or `gaato/http-async`? They are
now `gaato/mttp_core` and `gaato/mttp`.

The design follows the split of Scala's [sttp](https://sttp.softwaremill.com/)
family: a model, a client over swappable backends, and endpoint descriptions
interpreted as a server, a client and documentation.

## Install

```sh
moon add gaato/mttp_core
```

## Requests and backends

Values are immutable: each builder returns a copy.

```mbt check
///|
test "describe a request" {
  let request = @mttp_core.Request::post("https://api.example.com/v1/items")
    .query("dry_run", "true")
    .bearer("token")
    .body_json({ "name": "first" })
  assert_eq(request.url, "https://api.example.com/v1/items?dry_run=true")
  assert_eq(request.headers.get("content-type"), Some("application/json"))
  assert_false(@mttp_core.is_idempotent(request))
}
```

A `Backend` sends one exchange and returns the response. Every failure is a
`TransportError` whose phase says how far the exchange got, so `is_unsent`
tells whether resending a non-idempotent request is safe.

### On another runtime

`gaato/mttp` provides the backends for `moonbitlang/core/async`, on
native, wasm and js (through the host's `fetch`); wasm-gc has no runtime
there. A program on wasm-gc or on another runtime uses this module directly:
implement `Backend` over that runtime's HTTP client, or implement only the
ports in `rt` and reuse the `h1client` engine, then pass the backend, a
`Clock` and, for deadlines, a `Timer` to `Client::new`. The client, typed
endpoints and server-sent events work unchanged. A framework on the registry
module `moonbitlang/async` can share a program with `gaato/mttp`: from
0.22.6 on, that module runs on `moonbitlang/core/async`'s runtime, so an app
that needs it requires `moonbitlang/async@0.22.6` or later.

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
    @mttp_core.Response::new(
      200,
      headers=@mttp_core.Headers::of([("content-type", "application/json")]),
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

`gaato/mttp_core/driver` is experimental, so a test package that calls
`@driver.run_sync` lists it in its `moon.pkg`:
`options("allow-experimental-packages": [ "gaato/mttp_core/driver" ])`.

`Client::new` sends nothing it is not told to: retries, deadlines and rate
limits are opt-in here (`retry=`, `timeout_ms=`, `limiter=`), while
`gaato/mttp`'s `client()` turns retries and deadlines on for apps.
Redirects are followed by default, over any backend, a test function
included (`redirect=` configures them, `RedirectConfig::none()` turns them
off), and cookies are kept when the Client is given a jar (`cookies=`). The
`gaato/mttp_core/client/ratelimit` section below shows a limiter that follows a
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
`gaato/mttp`'s server or a JavaScript `fetch` export serves.

## Packages

| Package | What it holds |
|---|---|
| `gaato/mttp_core` | The vocabulary: methods, headers, URLs, requests, responses and bodies, `Backend` and `SendOptions`, `TransportError`, URL, form and HTTP-date (parse and format) helpers |
| `gaato/mttp_core/client` | Request and response plans with Result-valued readers, the `Client` loop (defaults, admission, deadlines, decoded-body limits, redirects, cookies, retries and the `RetryBudget`), `FollowRedirects`, `Paginator`, Retry-After and `Link` helpers |
| `gaato/mttp_core/client/retry` | Retry rules and decisions as data |
| `gaato/mttp_core/client/ratelimit` | Bounded window state, pacing, global quotas and header-driven admission |
| `gaato/mttp_core/client/cookies` | `Cookies`, the cookie-jar backend wrapper a Client with `cookies=` uses, for stacks built by hand |
| `gaato/mttp_core/sse` | A bounded `text/event-stream` parser, reader and encoder |
| `gaato/mttp_core/multipart` | A `multipart/form-data` writer with streamed parts |
| `gaato/mttp_core/cookie` | An RFC 6265 cookie jar on an injected clock |
| `gaato/mttp_core/jsonkit` | `Presence`, an object builder, field decoders and open enums for JSON models |
| `gaato/mttp_core/schema` | Text, JSON and body codecs that carry their JSON Schema, and validators |
| `gaato/mttp_core/endpoint` | Typed endpoint inputs and outputs, client calls and bounded server dispatch |
| `gaato/mttp_core/router` | Path and method dispatch, server policy, middleware, CORS; also a `Backend` |
| `gaato/mttp_core/openapi` | OpenAPI documents projected from endpoints, reference checks and a docs endpoint |
| `gaato/mttp_core/apispec` | OpenAPI document records with their JSON codecs (3.1, and 3.2's fields) |
| `gaato/mttp_core/endpoint/testkit` | Typed endpoint stubs and the definition checker |
| `gaato/mttp_core/testing` | `BackendStub`, canned answers and fault injection for client tests |
| `gaato/mttp_core/h1` | The sans-IO HTTP/1.1 codec: bounded decoders, strict parsers that refuse request smuggling, wire writers |
| `gaato/mttp_core/h1client` | The HTTP/1.1 client engine over the `rt` ports: connection pool, bounded heads and bodies, phase deadlines, proxies |
| `gaato/mttp_core/h1server` | The HTTP/1.1 server engine over the `rt` ports for one accepted connection |
| `gaato/mttp_core/rt` | The ports a runtime provides: `Clock`, `Timer`, `Gate`, `Conn`, `Dialer`, `Signal`, `Coordination` |
| `gaato/mttp_core/sim` | In-memory doubles of the ports and the contract checks every implementation passes |
| `gaato/mttp_core/driver` | A deterministic task driver with virtual time and `run_sync` for plain tests (experimental: it relies on compiler intrinsics) |

## License

Apache-2.0

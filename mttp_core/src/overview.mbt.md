# gaato/mttp_core

HTTP for MoonBit without I/O: request and response types, a client, HTTP/1.1
engines, typed endpoints with a router, and OpenAPI generation. It depends
only on `moonbitlang/core` and builds on Wasm GC, Wasm, JavaScript and native.

Use it in two situations:

- **You are writing a library, such as an API SDK.** Depend on this module and
  take a `Client`. The application decides how requests are sent, and tests
  can answer them with a plain function.
- **You are writing an app with `gaato/mttp`** and want typed endpoints, the
  router, OpenAPI, streaming downloads (`as_stream`) or test stubs. `gaato/mttp`
  provides the network backends and does not re-export these.

For a ready network client or socket server, start with
[`gaato/mttp`](https://mooncakes.io/docs/gaato/mttp).

## Install

```sh
moon add gaato/mttp_core
```

Import the subpackages you use by their full paths, such as
`gaato/mttp_core/client` or `gaato/mttp_core/endpoint`.

## Write a library against a client

A library takes a `Client` and leaves the backend to its caller. In a test,
the backend is a function.

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

**`Client::new` sends only what it is told to.** Retries, deadlines and rate
limits are opt-in (`retry=`, `timeout_ms=`, `limiter=`), while `gaato/mttp`'s
`client()` turns retries and deadlines on for apps. Redirects are followed by
default over any backend (`redirect=RedirectConfig::none()` turns them off).
Cookies are kept only when the client is given a jar (`cookies=`). A deadline
needs a `Timer` as well as the `Clock`.

Standard response readers put rejected statuses and decoding failures in
`reply.body`. Transport failures raise `TransportError`, whose phase says how
far the exchange got. `is_unsent()` is true only when the request provably
never reached the server, so resending it cannot duplicate it; false proves
nothing either way. `"\{error}"` and `failure.to_string()` give
readable messages for logs.

Requests are immutable: keep the value each builder returns.
`Request::get`, `post`, `put`, `patch`, `delete`, `options` and
`Request::new(method, url)` start one, and `@client.request(...)` turns it into
a plan the client sends. For an SDK-specific credential header, use
`.credential(name, value)` instead of `.header`, so that redirects to another
origin strip it and `to_curl` hides it.

## Share an endpoint between a service and its client

One definition gives a client call, a server handler behind a router and an
OpenAPI document. The test runs without a network or a server.

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

The router is itself a `Backend`, as above. Its `handler()` is what
`gaato/mttp`'s server or a JavaScript `fetch` export serves.

## On another runtime

`gaato/mttp` provides backends for `moonbitlang/core/async` on native, wasm and
js. A program on Wasm GC or on another runtime uses this module directly:
implement `Backend` over that runtime's HTTP client, or implement only the
ports in `rt` and reuse the `h1client` engine. Then pass the backend, a `Clock`
and a `Timer` to `Client::new`. The client, typed endpoints and server-sent
events work unchanged.
[Backend and runtime contracts](https://github.com/gaato/mttp/blob/main/CONTRACT.md)

## Find the package for a task

| Task | Where |
| --- | --- |
| Send requests with retries, budgets, quotas or a private cache | `client`, `client/retry`, `client/ratelimit`, `client/httpcache` |
| Stream a response body | `client` (`as_stream`, `as_lines`) |
| Stream server-sent events or multipart form data | `sse`, `multipart` |
| Validate JSON, route requests, generate or compare OpenAPI | `schema`, `endpoint`, `router`, `openapi`, `apispec`, `apispec/diff` |
| CORS, rate limits, secure headers, signed-cookie sessions on a server | `router` |
| Conditional and range requests (304, 412, 206) | `representation` |
| Compression dictionaries (RFC 9842): `Use-As-Dictionary`, a client dictionary store, URL patterns | `dictionary`, `urlpattern`. The coding itself, on client and server, is in `gaato/mttp`'s `codings` and `backend` packages. |
| WebSocket sessions | `ws` |
| Canned responses, fault injection, virtual time | `testing`, `sim`, `driver`, `endpoint/testkit` |
| Implement a runtime or transport | `rt`, `h1`, `h1client`, `h1server` |
| HTTP Digest authentication | the separate module [`gaato/mttp_digest`](https://mooncakes.io/docs/gaato/mttp_digest) |
| Codecs and schemas generated from annotated types | the separate tool [`gaato/mttp_schemagen`](https://mooncakes.io/docs/gaato/mttp_schemagen) |

Smaller building blocks: `cookie` (RFC 6265 jar), `cache` (RFC 9111 freshness
as pure functions), `sf` (RFC 9651 structured fields) and `jsonkit` (helpers
for JSON models).

## Links

- [Changelog](https://github.com/gaato/mttp/blob/main/mttp_core/CHANGELOG.md)
- [Migrating from MoonBit's built-in HTTP](https://github.com/gaato/mttp/blob/main/MIGRATING.md)
- [Repository](https://github.com/gaato/mttp)

## License

Apache-2.0

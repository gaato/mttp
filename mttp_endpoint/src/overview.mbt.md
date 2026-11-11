# gaato/mttp_endpoint

Typed HTTP endpoints for [MoonBit](https://www.moonbitlang.com/), in the style
of Scala's [tapir](https://tapir.softwaremill.com/), on top of
[`gaato/mttp`](https://mooncakes.io/docs/gaato/mttp). One endpoint definition
gives a client call through the `gaato/mttp` client, a server handler behind a
router, and an OpenAPI document. It does no I/O itself and runs on wasm-gc,
wasm, js and native.

## Install

```sh
moon add gaato/http gaato/mttp gaato/mttp_endpoint
```

A package that names `@http` or `@schema` types imports `gaato/http` or
`gaato/mttp` too, so list them in your `moon.mod`.

## Packages

| Package | What it holds |
|---|---|
| `gaato/mttp_endpoint/endpoint` | Typed endpoint inputs, output unions, Result-based client calls and bounded server dispatch over `gaato/http` |
| `gaato/mttp_endpoint/endpoint/testkit` | Typed endpoint stubs and the shared definition checker |
| `gaato/mttp_endpoint/router` | Path and method dispatch, bounded server policy, middleware, CORS and an in-process Backend |
| `gaato/mttp_endpoint/apispec` | OpenAPI 3.1 document records with their JSON codecs |
| `gaato/mttp_endpoint/openapi` | Checked OpenAPI 3.1 projection, schema reference checking and a documentation endpoint |

## Usage

Define an endpoint once, serve it through a router, call it with a client and
document it. The router is itself a `gaato/http` Backend, so this runs in
process; a listener from `gaato/http-async` serves the same router over a
socket.

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
  assert_eq(@openapi.check_references(spec), [])
}
```

## License

Apache-2.0. See
[LICENSE](https://github.com/gaato/mttp/blob/main/mttp_endpoint/LICENSE).

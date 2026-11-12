# mttp

[![CI](https://github.com/gaato/mttp/actions/workflows/ci.yml/badge.svg)](https://github.com/gaato/mttp/actions/workflows/ci.yml)
[![Ask DeepWiki](https://img.shields.io/badge/Ask-DeepWiki-blue)](https://deepwiki.com/gaato/mttp)
[![License](https://img.shields.io/github/license/gaato/mttp)](LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-gaato%2Fmttp__async-blue)](https://mooncakes.io/docs/gaato/mttp_async)
[![MoonBit 0.10.20+65efd5b93](https://img.shields.io/badge/MoonBit-0.10.20%2B65efd5b93-blue)](https://www.moonbitlang.com)

HTTP for [MoonBit](https://www.moonbitlang.com/) in which one endpoint
definition is your server, your typed client and your OpenAPI document, and
whose client retries within a budget and keeps deadlines without being asked.

[gaato/mttp_async](https://mooncakes.io/docs/gaato/mttp_async) ·
[gaato/mttp](https://mooncakes.io/docs/gaato/mttp) ·
[examples](#examples) ·
[backend contract](CONTRACT.md)

## One definition, three uses

<!-- source: examples/tour/main.mbt -->
```moonbit
///|
fn main {
  // Define it: GET /hello/{name} takes a String from the path, answers text.
  let hello = @endpoint.endpoint
    .get("/hello/{name}")
    .input(@endpoint.path("name", @schema.string))
    .output(@endpoint.text_out())
    .operation_id("hello")

  // Implement it. The clock and timer let the Router keep the client's
  // deadlines when it answers in-process, as below.
  let app = @router.Router::must(
    [hello.serve_public(name => Ok("hello, \{name}"))],
    clock=@mttp_async.clock(),
    timer=@mttp_async.timer(),
  )

  @mttp_async.run(async fn() {
    // Serve it on a port: `moon run examples/tour -- 127.0.0.1:8080`.
    if @env.args() is [_, addr] {
      @server.serve(app.handler(), addr~)
      return
    }

    // Call it with the typed client: a String goes in, a String comes back.
    // The Router is a Backend too, so here it answers without a port.
    let client = @mttp_async.client(backend=app)
    defer client.close()
    match hello.request((), "moon").send(client).body {
      Ok(Ok(greeting)) => println(greeting)
      _ => println("the call failed")
    }

    // Document it: the OpenAPI 3.1 document of the same definition.
    let spec = @openapi.to_openapi(
      [hello.doc()],
      @apispec.Info::new("Hello", "1.0.0"),
    )
    println(spec.to_json().stringify(indent=2))
  })
}
```

`moon run examples/tour` in a clone prints the greeting and the document,
which describes the path parameter, the text reply and the problem responses
the router sends for bad requests:

<!-- excerpt: examples/tour -->
```text
hello, moon
{
  "info": {
    "title": "Hello",
    "version": "1.0.0"
  },
  "paths": {
    "/hello/{name}": {
      "get": {
        "responses": {
          "200": {
            "description": "OK",
            "content": {
              "text/plain": {
                "schema": {
                  "type": "string"
                }
              }
            }
          },
          "400": {
            "description": "Bad Request",
            ...
        "operationId": "hello",
        "parameters": [
          {
            "name": "name",
            "in": "path",
            "required": true,
            "schema": {
              "type": "string"
            }
          }
        ],
        "security": []
      }
    }
  },
  "openapi": "3.1.0",
  ...
}
```

## Retries you can watch

[examples/retries](examples/retries) starts a server on a local port that
answers 503 twice and then 200, and calls it with the retry policy and budget
that `@mttp_async.client()` uses by default, printing each attempt:

<!-- output: examples/retries -->
```text
attempt 1: 503, retry in 500 ms
attempt 2: 503, retry in 1000 ms
attempt 3: 200, done
result: 200 ready
```

The wait doubles from 500 ms. Each wait is normally spread by up to 20 %
either way so that clients do not retry in step; the example fixes the spread
at its middle, so it prints the same on every run. The GET is retried because
it is idempotent: a POST is retried only when it was never sent, or when the
caller marks it safe to replay.

## Beside `moonbitlang/core/async/http`

For a simple GET the standard library is enough: `@http.get_text(url)` is one
line and adds no dependency. mttp is for what grows around that call:

| | `moonbitlang/core/async/http` | mttp |
|---|---|---|
| Retries with a budget | No | On by default: idempotent requests on 408, 409, 429, 500, 502, 503 and 504 and on network failures, honouring `Retry-After`, within a retry budget so that a failing server is not flooded |
| Deadlines per attempt and total | None built in; wrap a call in `@async.with_timeout` | On by default: 30 s per attempt, 120 s per call with its retries |
| Rate limits | No | `limiter=`: windows, pacing, global quotas and limits read from the server's headers |
| Redirects | Not followed on native and wasm; on js the host's `fetch` follows them | Up to 10 hops, never from HTTPS to HTTP, credentials dropped across origins |
| Cookies | `Set-Cookie` parsed into `ResponseHeader.cookies`; no jar | An RFC 6265 jar (`cookies=`), applied on every redirect hop |
| Decompression | gzip on native and wasm | gzip, deflate, br and zstd on native and wasm |
| Connection reuse | `Client` opens a connection per request (its README says pooling is planned) | Pooled connections per Client |
| Typed failures | Errors are raised; a 404 is a response like any other | An HTTP failure (a status, a body that does not decode) is a value in `reply.body`; a network failure is a `TransportError` that says in which phase it happened and whether the request was sent |
| Typed endpoints and OpenAPI | No | One definition gives the handler, the client call and an OpenAPI 3.1 document |
| Server | HTTP/1.1 on native and wasm; a handler writes the response head and body to the connection | HTTP/1.1 on native and wasm; a handler is `async (Request) -> Response`, with bounded connections, heads and bodies and a graceful shutdown |
| JS hosts | The client, over `fetch` | The client, over `fetch`; handlers as a `fetch` export for Cloudflare Workers, Deno, Bun, Node, Fastly, Vercel and AWS Lambda |
| Testing without the network | No backend to swap: test against a local server | Any `Backend`: a function, `BackendStub` or a Router; a virtual clock for retries and deadlines |
| wasm-gc | No: native, wasm and js | `gaato/mttp` builds and tests there; the program provides the runtime's ports, as no network backend ships for it |

On js both clients send through the host's `fetch`, which decompresses and
reuses connections itself; mttp's Client still follows redirects by the rules
above.

## Modules

| Module | Add it if |
|---|---|
| [`gaato/mttp_async`](https://mooncakes.io/docs/gaato/mttp_async) | you are building an app or a server: it sends requests over the network with the defaults above, serves handlers, and re-exports the types and client functions an app uses most. Add `gaato/mttp` beside it for typed endpoints, the router, OpenAPI documents, multipart bodies, rate limits and test stubs. |
| [`gaato/mttp`](https://mooncakes.io/docs/gaato/mttp) | you are writing a library, such as an SDK for some API: it takes a `Client` and leaves the network to the app, so its tests run without one. |
| [`gaato/mttp_digest`](https://mooncakes.io/docs/gaato/mttp_digest) | a server asks for HTTP Digest authentication. |
| [`gaato/mttp_moonfetch`](https://mooncakes.io/docs/gaato/mttp_moonfetch) | you want HTTP/2 or HTTP/3 under mttp's Client on native and wasm: give its `backend()` to `@mttp_async.client(backend=...)`. |

`gaato/mttp` holds everything without I/O and builds on every target;
`gaato/mttp_async` connects it to the network through `moonbitlang/core/async`;
`gaato/mttp_digest` adds Digest authentication to either; and
`gaato/mttp_moonfetch` is a second network backend, over
[moonbitstack/moonfetch](https://mooncakes.io/docs/moonbitstack/moonfetch),
that speaks HTTP/2 and HTTP/3 as well. The split follows Scala's
[sttp](https://sttp.softwaremill.com/) family.

### Examples

- [examples/tour](examples/tour): the endpoint above, served, called and
  documented.
- [examples/retries](examples/retries): the retries above.
- [examples/get](examples/get): one GET request from the command line.
- [examples/serve](examples/serve): an HTTP/1.1 server.
- [examples/fetch](examples/fetch): a `fetch` export for JavaScript hosts,
  with a [Cloudflare Workers app](examples/fetch/workers).

## How it is checked

CI runs two jobs on every push and pull request, and runs them again daily
on the latest and nightly toolchains: [`scripts/gates.sh`](scripts/gates.sh)
`full` for every module but `gaato/mttp_moonfetch`, and `moonfetch` for it.
mttp_moonfetch runs on moonbitstack's code, so when a toolchain or a
moonbitstack release breaks that, its job fails alone. Between them they
check:

- The modules without I/O, `gaato/mttp` and `gaato/mttp_digest`, run the same
  tests on wasm-gc, wasm, js and native.
  [scripts/test_manifest.tsv](scripts/test_manifest.tsv) records how many
  each package runs on each target, and the gates fail when a count changes
  unrecorded or differs between targets.
- [conformance](conformance) checks URL parsing against WHATWG URL test
  vectors, and forms and cookies against WPT and http-state data, on all four
  targets.
- [RESOURCE_BOUNDS.md](RESOURCE_BOUNDS.md) lists every structure that grows
  with input from the network or with the number of requests, with its bound
  and the test that drives it past that bound.
- [CONTRACT.md](CONTRACT.md) states what a backend, a runtime adapter or a
  test double must guarantee; the same contract checks run against the
  in-memory doubles, against `gaato/mttp_async`'s adapters and against
  `gaato/mttp_moonfetch`'s backend.
- `gaato/mttp_moonfetch` runs on native and wasm against local HTTP/1.1 and
  HTTP/2 servers. The daily run also builds it against the newest moonfetch
  and talks to public HTTP/2 and HTTP/3 servers, which the pull-request jobs
  never reach.
- [TEST_COVERAGE.md](TEST_COVERAGE.md) names a reason for every line the
  tests do not cover.
- The [Cloudflare Workers app](examples/fetch/workers) runs on real workerd,
  through the wrangler version its lockfile pins.
- The code and outputs in this README are those of the examples;
  [scripts/readme_check.mbtx](scripts/readme_check.mbtx) compares them.

## Status

The modules are at 0.x: a minor release (0.1 → 0.2) may break the API, and a
patch release never does. Each module's changelog, such as
[mttp/CHANGELOG.md](mttp/CHANGELOG.md), says what changed and what to rename.

One package is experimental: `gaato/mttp/driver`, the deterministic task
driver behind `run_sync` in tests, because it relies on compiler intrinsics
that may change. A package that imports it lists it in its `moon.pkg`:
`options("allow-experimental-packages": [ "gaato/mttp/driver" ])`.

`gaato/mttp_async` runs on `moonbitlang/core/async`, which the toolchain still
marks experimental. Its `run` and `client()` keep that opt-in out of an app's
`moon.pkg`; code that imports core/async itself, to spawn tasks for example,
lists it. The gates run on the toolchain that
[moonbit-version](moonbit-version) pins.

## Coming from gaato/http

`gaato/http` and `gaato/http-async` are now `gaato/mttp` and
`gaato/mttp_async`; the [changelog of gaato/mttp](mttp/CHANGELOG.md) says
what to rename.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

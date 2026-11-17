# mttp

[![CI](https://github.com/gaato/mttp/actions/workflows/ci.yml/badge.svg)](https://github.com/gaato/mttp/actions/workflows/ci.yml)
[![Ask DeepWiki](https://img.shields.io/badge/Ask-DeepWiki-blue)](https://deepwiki.com/gaato/mttp)
[![License](https://img.shields.io/github/license/gaato/mttp)](LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-gaato%2Fmttp-blue)](https://mooncakes.io/docs/gaato/mttp)
[![MoonBit 0.10.21+06da1ed44](https://img.shields.io/badge/MoonBit-0.10.21%2B06da1ed44-blue)](https://www.moonbitlang.com)

HTTP for [MoonBit](https://www.moonbitlang.com/) — client, server and
WebSockets, on native, wasm and JS hosts. One endpoint definition is your
handler, your typed client and your OpenAPI document, with external suites
across the stack, fuzzing of protocol readers and proofs for the HTTP/1
number core.

[gaato/mttp](https://mooncakes.io/docs/gaato/mttp) ·
[gaato/mttp_core](https://mooncakes.io/docs/gaato/mttp_core) ·
[examples](#examples) ·
[backend contract](CONTRACT.md)

## Start

An app adds one module:

```sh
moon add gaato/mttp
```

and its package imports `"gaato/mttp"`. This is
[examples/get](examples/get), which sends one GET request with retries,
deadlines, redirects and decompression on, and runs on native, wasm and js:

<!-- source: examples/get/main.mbt -->
```moonbit
///|
fn main {
  @mttp.run(async fn() {
    let client = @mttp.client()
    defer client.close()
    let reply = client.send(@mttp.get("https://example.com/"))
    match reply.body {
      Ok(text) => println("\{reply.status}: \{text.length()} characters")
      Err(failure) => println("\{reply.status}: \{failure}")
    }
  })
}
```

Serve a handler with `gaato/mttp/server`. This is
[examples/serve](examples/serve); run it with
`moon run examples/serve -- 127.0.0.1:8080`:

<!-- source: examples/serve/main.mbt -->
```moonbit
///|
async fn main {
  let args = @env.args()
  guard args.length() == 2 else {
    println("usage: serve <address>")
    @env.exit(2)
  }
  @server.serve(
    _ => @mttp.Response::new(200, body=Bytes(b"hello\n")),
    addr=args[1],
    on_listen=addr => println("listening on \{addr}"),
  )
}
```

## One definition, three uses

Typed endpoints come from `gaato/mttp_core`, the part of the family without
I/O, so that a definition can be shared with code that builds on wasm-gc. An
app that uses them adds it beside gaato/mttp (`moon add gaato/mttp_core`):

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
    clock=@mttp.clock(),
    timer=@mttp.timer(),
  )

  @mttp.run(async fn() {
    // Serve it on a port: `moon run examples/tour -- 127.0.0.1:8080`.
    if @env.args() is [_, addr] {
      @server.serve(app.handler(), addr~)
      return
    }

    // Call it with the typed client: a String goes in, a String comes back.
    // The Router is a Backend too, so here it answers without a port.
    let client = @mttp.client(backend=app)
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

Serve documentation with `@openapi.docs_endpoint(spec)` and
`@openapi.docs_ui_endpoint(spec_url="/openapi.json")` in the router's endpoints.
Scalar is the default at `/docs`; pass `ui=SwaggerUi` for Swagger UI.
The specification must be same-origin under the page's CSP. To emit OpenAPI
3.2.0 with SSE `itemSchema`, pass `version=V3_2` to `to_openapi`; the default
remains 3.1.0 for client-generator compatibility.

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
that `@mttp.client()` uses by default, printing each attempt:

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
| Retries, deadlines and admission | Wrap calls in `@async.with_timeout`; no retry or admission policy | Budgeted retries and 30 s / 120 s deadlines by default; opt-in window, pacing and header-driven rate limits |
| Redirects | Not followed on native and wasm; on js the host's `fetch` follows them | Up to 10 hops, never from HTTPS to HTTP, credentials dropped across origins |
| Cookies | `Set-Cookie` parsed on native/wasm; no jar | An RFC 6265 jar (`cookies=`), applied on every redirect hop |
| Content codings | gzip response decoding on native and wasm; no request compressor | gzip, deflate, br and zstd decoding; opt-in request body compression |
| Connection reuse | `Client` opens a connection per request | Pooled connections per Client |
| Typed failures | Errors raised; a 404 is an ordinary response | HTTP/decoding failures in `reply.body`; `TransportError` identifies phase and whether the request was sent |
| Typed endpoints and OpenAPI | No | One definition gives handler, client and OpenAPI 3.1 or 3.2; structural compatibility diff |
| Server | HTTP/1.1 on native and wasm; writes head and body to a connection | Native/wasm engine: HTTP/1.1; JS fetch/server: host-negotiated versions. HTTP/2 engine awaits ALPN in core/tls. Bounded `Request -> Response` handlers, graceful shutdown |
| WebSockets | Separate `core/async/websocket`: client and server on native/wasm; no extensions | Client and server; opt-in permessage-deflate on native/wasm; Autobahn both directions; JS host sessions |
| Server middleware | No policy layer | `rate_limit` with RateLimit headers, `secure_headers`, signed-cookie sessions, CORS |
| Representations | Raw headers and bodies; no selection or file handler | Accept negotiation and 406; conditionals 304/412; static files with opt-in Range 206/416 |
| Private HTTP cache | No cache policy; JS fetch is host-managed | Opt-in RFC 9111 cache: Vary, validators, credential partitions and bounded memory |
| Resilience and observation | No resilience policies or client events | Circuit breaker, credential refresh, SSE reconnection; client events and W3C trace context |
| Testing without the network | No swappable backend | Function backends, `BackendStub`, Router and virtual clocks |
| wasm-gc | No: native, wasm and js | All of `gaato/mttp_core`; supply runtime ports for I/O |

On js both clients send through the host's `fetch`, which decompresses and
reuses connections itself; mttp's Client still follows redirects by the rules
above. mttp exports handlers for Cloudflare Workers, Deno, Bun, Node,
Fastly, Vercel and AWS Lambda. WebSocket upgrades are available on Workers,
Deno and Bun; see the [host matrix](mttp/hosts/README.md#websockets).
The standard-library column describes the toolchain pinned in
[moonbit-version](moonbit-version), including its separate WebSocket package.

## Modules

| Module | Add it if |
|---|---|
| [`gaato/mttp`](https://mooncakes.io/docs/gaato/mttp) | you are building an app or a server: it sends requests over the network with the defaults above, serves handlers, and re-exports the types, request attributes and client functions an app uses. Add `gaato/mttp_core` beside it for typed endpoints, the router, OpenAPI documents, multipart bodies, rate limits and test stubs. |
| [`gaato/mttp_core`](https://mooncakes.io/docs/gaato/mttp_core) | you are writing a library, such as an SDK for some API: it takes a `Client` and leaves the network to the app, so it builds on every target, wasm-gc included, and its tests run without a network. |
| [`gaato/mttp_digest`](https://mooncakes.io/docs/gaato/mttp_digest) | a server asks for HTTP Digest authentication. |

`gaato/mttp_core` holds everything without I/O and builds on every target;
`gaato/mttp` connects it to the network through `moonbitlang/core/async`;
`gaato/mttp_digest` adds Digest authentication to either. The split follows
Scala's [sttp](https://sttp.softwaremill.com/) family.

Packages to look for (paths below are under `gaato/mttp_core` unless noted):

- `ws`: portable WebSocket sessions and codecs; `gaato/mttp/ws` connects and upgrades them, with permessage-deflate.
- `client/httpcache`: the opt-in private HTTP cache.
- `representation`: content negotiation, validators, preconditions and byte ranges; `gaato/mttp/files` applies them to files.
- `apispec/diff`: structural OpenAPI compatibility reports for clients and servers.
- `multipart`: streamed form-data writing and bounded reading, also used by typed endpoint inputs.
- `router`: dispatch and middleware, including rate limits, security headers and signed-cookie sessions.

### Examples

- [examples/tour](examples/tour): the endpoint above, served, called and
  documented.
- [examples/retries](examples/retries): the retries above.
- [examples/get](examples/get): one GET request, on native, wasm and js.
- [examples/serve](examples/serve): the server above.
- [examples/fetch](examples/fetch): a `fetch` export for JavaScript hosts,
  with a [Cloudflare Workers app](examples/fetch/workers).

## How it is checked

[`scripts/gates.sh full`](scripts/gates.sh) checks all supported targets,
documentation and ledgers, plus the Workers example on real workerd, on
pushes and pull requests. Daily canaries repeat this on latest and nightly
toolchains; separate pinned-toolchain jobs run interop, sanitizers, fuzzing
and benchmarks. Mutation testing and proofs are manual gates.

- The modules without I/O, `gaato/mttp_core` and `gaato/mttp_digest`, run the same
  tests on wasm-gc, wasm, js and native.
  [scripts/test_manifest.tsv](scripts/test_manifest.tsv) records how many
  each package runs on each target, and the gates fail when a count changes
  unrecorded or differs between targets.
- [conformance](conformance) checks URL parsing against WHATWG URL test
  vectors, forms and cookies against WPT and http-state data, and the HTTP/1
  codec against llhttp's tests and WPT's response parsing tables, on all four
  targets.
- [RESOURCE_BOUNDS.md](RESOURCE_BOUNDS.md) lists every structure that grows
  with input from the network or with the number of requests, with its bound
  and the test that drives it past that bound.
- [SECURITY_CLASSES.md](SECURITY_CLASSES.md) maps HTTP vulnerability classes
  to the exact regression tests that defend mttp, or to the planned work that
  must close the remaining feature gap.
- [CONTRACT.md](CONTRACT.md) states what a backend, a runtime adapter or a
  test double must guarantee; the same contract checks run against the
  in-memory doubles and against `gaato/mttp`'s adapters.
- [TEST_COVERAGE.md](TEST_COVERAGE.md) names a reason for every line the
  tests do not cover.
- The code and outputs in this README are those of the examples;
  [scripts/readme_check.mbtx](scripts/readme_check.mbtx) compares them.
- Daily, the native tests of `gaato/mttp_core` and `gaato/mttp`, with the
  C they link, run under AddressSanitizer (`scripts/gates.sh sanitize`).
- The [interop suite](interop) checks the client against nginx, Caddy and
  Apache, and the server against curl, Go, httpx, Node, Bun and Deno, directly
  and through reverse proxies. Http11Probe probes protocol compliance;
  Schemathesis checks typed endpoints against their OpenAPI document.
  [HTTP Garden](interop/README.md#http-garden) has a manual differential
  testing adapter.
- Autobahn checks WebSockets in both directions, including permessage-deflate.
  The [recorded native client run](interop/README.md) has 460 passes,
  57 exact known verdicts and 0 unexpected failures. Known compression cases
  in both directions reflect the fixed 15-bit encoding window; raw suite
  verdicts, including FAILED, remain visible rather than becoming passes.
- [Coverage-guided fuzzing](fuzz) runs the HTTP/1 reader and WebSocket frame
  parser through libFuzzer and AddressSanitizer. The manual
  [mutation sample](scripts/mutate.mbtx) checks HTTP/1 framing regressions.
- [Proofs](mttp_core/src/h1/PROOFS.md) with Z3 and CVC5 cover the integer
  core used for Content-Length and chunk-size, including overflow rejection.
  Strings, byte conversion and the rest of framing are tested integration
  code outside the proof.
- The [transport benchmarks](benchmarks/README.md) compare mttp with
  core/async/http, Go and Node on pinned loopback workloads; CI records the
  daily table as an artifact without treating performance as a pass/fail
  threshold (`scripts/gates.sh bench`).

## Status

The engine mttp runs on native and wasm speaks HTTP/1.1; on JS hosts the
host's fetch and server use whatever version they negotiate. An HTTP/2
engine awaits ALPN in core/tls.

The modules are at 0.x: a minor release (0.1 → 0.2) may break the API, and a
patch release never does. Each module's changelog, such as
[mttp/CHANGELOG.md](mttp/CHANGELOG.md), says what changed and what to rename.

One package is experimental: `gaato/mttp_core/driver`, the deterministic task
driver behind `run_sync` in tests, because it relies on compiler intrinsics
that may change. A package that imports it lists it in its `moon.pkg`:
`options("allow-experimental-packages": [ "gaato/mttp_core/driver" ])`.

`gaato/mttp` runs on `moonbitlang/core/async`, which the toolchain still
marks experimental. Its `run` and `client()` keep that opt-in out of an app's
`moon.pkg`; code that imports core/async itself, to spawn tasks for example,
lists it. The gates run on the toolchain that
[moonbit-version](moonbit-version) pins.

## Renamed modules

Up to gaato/mttp 0.2, the name `gaato/mttp` was the part without I/O, and the
module an app adds was `gaato/mttp_async`. From 0.3, `gaato/mttp` is the
module an app adds (formerly gaato/mttp_async) and the part without I/O is
`gaato/mttp_core`. The [changelog of gaato/mttp](mttp/CHANGELOG.md) has a
table of what to replace, in which order.

`gaato/http` and `gaato/http-async`, the modules before those, are now
`gaato/mttp_core` and `gaato/mttp`; the
[changelog of gaato/mttp_core](mttp_core/CHANGELOG.md) says what to rename.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

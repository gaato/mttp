# gaato/mttp_async

HTTP for MoonBit apps that need more than the standard library's client: an
API client with retries under a budget, deadlines, redirects, decompression
and typed failures, plus an HTTP/1.1 server, on `moonbitlang/core/async` for
native, wasm and js. It is the one module an app adds.

Writing a library, such as an SDK for some API? Depend on
[`gaato/mttp`](https://mooncakes.io/docs/gaato/mttp) instead: it has the same
types and client without any I/O, so it builds on every target and the app
chooses how requests are sent.

## Install

```sh
moon add gaato/mttp_async
```

## Call an API

```mbt check
///|
/// Fetches a user and prints it, or the status that stopped it.
pub async fn print_user(id : Int32) -> Unit {
  let api = @mttp_async.client(base_url="https://api.example.com")
  defer api.close()
  let reply = api.send(
    @mttp_async.get("/users/\{id}").response(@mttp_async.as_json_value()),
  )
  match reply.body {
    Ok(user) => println(user.stringify())
    Err(_) => println("HTTP \{reply.status}")
  }
}
```

Start it from `fn main` with `run`; the app imports neither
`moonbitlang/core/async` nor its experimental opt-in:

```mbt nocheck
///|
fn main {
  @mttp_async.run(async fn() { print_user(1) })
}
```

`get`, `post` and `request` build a request; `as_json`, `as_json_value`,
`as_string`, `as_bytes`, `as_lines` and `as_sse` say how to read the reply.
An HTTP failure, such as a 404 or a body that does not decode, is a value in
`reply.body`; a network failure is raised as a `TransportError` that says in
which phase it happened and whether the request was sent.

## What `client()` does by default

| | Default | Change it with |
|---|---|---|
| Retries | Up to two, for idempotent requests on 408, 409, 429, 5xx and network failures, and for any request that was never sent; `Retry-After` is honoured, backoff is exponential with jitter | `retry=RetryPolicy::none()` or another policy |
| Retry budget | Retries stay within 20 % of the requests of the last 10 s, plus 10 per second, so a failing server is not flooded | `retry_budget=RetryBudget::new(..)` or `RetryBudget::unlimited()` |
| Deadlines | 30 s per attempt, 120 s for the whole call, retries included | `timeout_ms=`, `total_ms=` |
| Redirects | Up to 10 hops, never from HTTPS to HTTP, credentials dropped across origins | `redirect=`, or `.follow_redirects(false)` on a request |
| Decompression | gzip, deflate, br and zstd | per request, by setting `Accept-Encoding` |
| Body size | Buffered bodies up to 64 MiB after decoding | `max_body_bytes=` |
| TLS | The system's roots | `trust=PemFile(..)` |

## Serve

`gaato/mttp_async/server` serves any `async (Request) -> Response` handler on
native and wasm, with bounded connections, headers and bodies and a graceful
shutdown:

```mbt nocheck
@server.serve(request => @mttp_async.Response::new(200), addr="127.0.0.1:8080")
```

For typed endpoints with request validation and an OpenAPI document, define
them with `gaato/mttp`'s `endpoint` and `router` packages (add `gaato/mttp`
to the app as well) and serve `router.handler()`. On JavaScript hosts,
`gaato/mttp_async/fetch` turns the same handler into a `fetch` export for
Cloudflare Workers, Deno, Bun, Node, Fastly, Vercel and AWS Lambda.

## Targets

native, wasm (under moonrun) and js. On js the client uses the host's `fetch`,
which decides proxies, pooling and decompression itself. wasm-gc has no
runtime here; use `gaato/mttp` there and provide its runtime ports.

## Packages

| Package | Targets | Purpose |
|---|---|---|
| `gaato/mttp_async` | native, wasm, js | `run`, `client()`, and re-exports of the types and client functions an app uses |
| `backend` | native, wasm, js | `AsyncBackend`: the HTTP/1.1 engine over TCP and TLS with decompression; the host's `fetch` on js |
| `server` | native, wasm | `serve`: bounded listener, graceful shutdown, background work |
| `fetch`, `hosts` | js | `fetch_handler` and the host shims |
| `runtime` | native, wasm, js | Clocks, timers, an admission gate and coordination for `gaato/mttp`'s runtime ports |
| `codings` | native, wasm, js | Bounded content codecs, `Decompress` for clients and `compress` for handlers |
| `conn` | native, wasm | TCP and TLS dialing, including CONNECT tunnels |
| `trust` | native, wasm, js | `Trust`: which TLS roots a socket backend accepts |

## License

Apache-2.0

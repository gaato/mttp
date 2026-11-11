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
/// Fetches a user and prints it, the status that stopped it, or the network
/// failure.
pub async fn print_user(id : Int32) -> Unit {
  let api = @mttp_async.client(base_url="https://api.example.com")
  defer api.close()
  let reply = api.send(
    @mttp_async.get("/users/\{id}").response(@mttp_async.as_json_value()),
  ) catch {
    error => {
      println("network: \{error}")
      return
    }
  }
  match reply.body {
    Ok(user) => println(user.stringify())
    Err(failure) => println(failure.to_string())
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
which phase it happened and whether the request was sent. Both print as
readable messages.

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

## With an API SDK

An SDK built on `gaato/mttp` (such as `gaato/openai` or `gaato/anthropic`)
creates its own Client with the provider's base URL, authentication and retry
rules. Give it the I/O with `backend()`, `clock()` and `timer()`; the timer
lets it enforce its deadlines:

```mbt nocheck
///|
let claude = @anthropic.Anthropic::new(
  api_key~,
  @mttp_async.backend(),
  @mttp_async.clock(),
  timer=@mttp_async.timer(),
)
```

The app's `moon.mod` lists the SDK and `gaato/mttp_async`.

## Serve

`gaato/mttp_async/server` serves any `async (Request) -> Response` handler on
native and wasm, with bounded connections, headers and bodies and a graceful
shutdown:

```mbt nocheck
@server.serve(request => @mttp_async.Response::new(200), addr="127.0.0.1:8080")
```

A request body arrives as a stream. `Body::read_all(max~)` reads it into
memory and refuses more than `max` bytes:

```mbt check
///|
/// Echoes a request body of up to 64 KiB; a larger one gets 413.
pub async fn echo(
  request : @mttp_async.Request,
) -> @mttp_async.Response noraise {
  let body = request.body.read_all(max=65536) catch {
    TransportError(kind=TooLarge(..), ..) =>
      return @mttp_async.Response::new(413)
    _ => return @mttp_async.Response::new(400)
  }
  @mttp_async.Response::new(200, body=Bytes(body))
}
```

The server binds with `SO_REUSEADDR`, as Go's and Node's servers do, so a
restarted process can listen again while the old one's connections wait out
TIME-WAIT. It does not let two running servers share a port.

For typed endpoints with request validation and an OpenAPI document, define
them with `gaato/mttp`'s `endpoint` and `router` packages (add `gaato/mttp`
to the app as well) and serve `router.handler()`. An app with forms and a
cookie session adds the router's `same_origin` middleware, which refuses
state-changing requests from other sites, and sets its cookies `SameSite`.
On JavaScript hosts, `gaato/mttp_async/fetch` turns the same handler into a
`fetch` export for Cloudflare Workers, Deno, Bun, Node, Fastly, Vercel and AWS
Lambda. `gaato/mttp_async/files` serves a directory's files, such as
stylesheets and scripts, as one more handler, alone or behind a Router's 404s.

## Tests and concurrency

A plain `test` block runs async code with `run`, again without importing
core/async:

```mbt nocheck
///|
test "reads the user" {
  @mttp_async.run(async fn() { print_user(1) })
}
```

Running work concurrently (spawning tasks, task groups, `async test`) is
`moonbitlang/core/async`'s job: import it and list it in the package's
`allow-experimental-packages`. This module does not re-export it, because
its public API names no runtime types.

## Targets

native, wasm (under moonrun) and js. On js the client uses the host's `fetch`,
which decides proxies, pooling and decompression itself. wasm-gc has no
runtime here; use `gaato/mttp` there and provide its runtime ports.

## Packages

| Package | Targets | Purpose |
|---|---|---|
| `gaato/mttp_async` | native, wasm, js | `run`, `client()`, `backend()`, `clock()`, `timer()`, and re-exports of the types and client functions an app uses |
| `backend` | native, wasm, js | `AsyncBackend`: the HTTP/1.1 engine over TCP and TLS with decompression; the host's `fetch` on js |
| `server` | native, wasm | `serve`: bounded listener, graceful shutdown, background work |
| `files` | native, wasm | `static_files`: a directory's files for GET and HEAD, streamed, with ETag revalidation and paths kept inside the directory |
| `fetch`, `hosts` | js | `fetch_handler` and the host shims |
| `runtime` | native, wasm, js | Clocks, timers, an admission gate and coordination for `gaato/mttp`'s runtime ports |
| `codings` | native, wasm, js | Bounded content codecs, `Decompress` for clients and `compress` for handlers |
| `conn` | native, wasm | TCP and TLS dialing, including CONNECT tunnels |
| `trust` | native, wasm, js | `Trust`: which TLS roots a socket backend accepts |

## License

Apache-2.0

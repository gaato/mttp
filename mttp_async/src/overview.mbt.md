# gaato/mttp_async

HTTP for MoonBit apps that need more than the standard library's client: an
API client with retries under a budget, deadlines, redirects, cookies,
decompression and typed failures, plus an HTTP/1.1 server, on
`moonbitlang/core/async` for native, wasm and js. It is the module an app
starts with; an app that calls APIs and serves plain handlers needs no other.

Add [`gaato/mttp`](https://mooncakes.io/docs/gaato/mttp) to the app as well
when it uses the parts without I/O that this module does not re-export:
typed endpoints, the router and OpenAPI documents, multipart forms, rate
limits such as `WindowLimiter`, the request attributes `@mttp.background`
and `@mttp.remote_addr`, or the test doubles of `gaato/mttp/testing`.

Writing a library, such as an SDK for some API? Depend on `gaato/mttp` only:
it has the same types and client without any I/O, so it builds on every
target and the app chooses how requests are sent.

## Install

```sh
moon add gaato/mttp_async
```

## Call an API

```mbt check
///|
pub async fn show_user() -> Unit {
  let api = @mttp_async.client(base_url="https://api.example.com")
  defer api.close()
  let user = @mttp_async.get("/users/1").response(@mttp_async.as_json_value())
  match api.send(user).body {
    Ok(json) => println(json.stringify())
    Err(failure) => println(failure)
  }
}
```

Start it from `fn main` with `run`; the app imports neither
`moonbitlang/core/async` nor its experimental opt-in:

```mbt nocheck
///|
fn main {
  @mttp_async.run(show_user)
}
```

`get`, `post` and `request` build a request; `as_json`, `as_json_value`,
`as_string`, `as_bytes`, `as_lines` and `as_sse` say how to read the reply.
An HTTP failure, such as a 404 or a body that does not decode, is a value in
`reply.body`. A network failure is raised as a `TransportError` that says in
which phase it happened and whether the request was sent; catch it where the
app can do something about it:

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
    Err(failure) => println("HTTP: \{failure}")
  }
}
```

## What `client()` does by default

| | Default | Change it with |
|---|---|---|
| Retries | Up to two, for idempotent requests on 408, 409, 429, 500, 502, 503 and 504 and on network failures, and for any request that was never sent; `Retry-After` is honoured, and a server that asks to wait more than 60 s is not retried; backoff is exponential with jitter | `retry=RetryPolicy::none()` or another policy |
| Retry budget | Retries stay within 20 % of the requests of the last 10 s, plus 10 per second, so a failing server is not flooded | `retry_budget=RetryBudget::new(..)` or `RetryBudget::unlimited()` |
| Deadlines | 30 s per attempt, 120 s for the whole call, retries included | `timeout_ms=`, `total_ms=` |
| Redirects | Up to 10 hops, never from HTTPS to HTTP, credentials dropped across origins | `redirect=`, `redirect=RedirectConfig::none()` to turn them off, or `.follow_redirects(false)` on a request |
| Cookies | None kept | `cookies=` a `CookieJar` |
| Decompression | gzip, deflate, br and zstd | per request, by setting `Accept-Encoding` |
| Body size | Buffered bodies up to 64 MiB after decoding | `max_body_bytes=` |
| TLS | The system's roots | `trust=PemFile(..)` |

## Cookies

A Client keeps no cookies unless it is given a jar. With `cookies=`, every
response's `Set-Cookie` is stored, and matching cookies are sent with each
request, on every redirect hop too, so a login that answers with a redirect
and a cookie works as in a browser:

```mbt check
///|
/// Logs in, then reads a page that needs the session cookie.
pub async fn account_page(token : String) -> String? {
  let jar = @mttp_async.CookieJar::new(@mttp_async.clock())
  let site = @mttp_async.client(base_url="https://shop.example", cookies=jar)
  defer site.close()
  ignore(site.send(@mttp_async.post("/login").body_json({ "token": token })))
  site.send(@mttp_async.get("/account")).body.to_option()
}
```

The jar belongs to the caller: several Clients may share it, and it outlives
them. A Client built with `Client::new` takes one the same way, `cookies=`.
The jar does not apply browsers' `SameSite` rules.

## With an API SDK

An SDK built on `gaato/mttp` (such as `gaato/openai` or `gaato/anthropic`)
creates its own Client with the provider's base URL, authentication and retry
rules. Give it the I/O with `backend()`, `clock()` and `timer()`; the timer
lets it enforce its deadlines. `backend()` is the network alone, HTTP/1.1
with decompression; the SDK's Client follows redirects itself, as every
`Client` does:

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
TIME-WAIT. On Linux a second server still cannot take a port that is being
listened on; on macOS and the BSDs a bind to a specific address can coexist
with an earlier wildcard bind of the same port.

An app with forms and a cookie session adds the router's `same_origin`
middleware, which refuses state-changing requests from other sites, and sets
its cookies `SameSite`. On JavaScript hosts, `gaato/mttp_async/fetch` turns
the same handler into a `fetch` export for Cloudflare Workers, Deno, Bun,
Node, Fastly, Vercel and AWS Lambda. `gaato/mttp_async/files` serves a
directory's files, such as stylesheets and scripts, as one more handler,
alone or behind a Router's 404s.

## A complete app

A typed endpoint validates its request and documents itself for OpenAPI; a
Router serves a set of them as one handler. They come from `gaato/mttp`, so
the app's `moon.mod` lists both modules (`moon add gaato/mttp`), and its
`moon.pkg` imports what it uses:

```text
import {
  "gaato/mttp_async",
  "gaato/mttp_async/server",
  "gaato/mttp/endpoint",
  "gaato/mttp/router",
  "gaato/mttp/schema",
}

pkgtype(kind: "executable")
```

```mbt check
///|
/// GET /hello/{name} answers with a greeting.
let hello : @endpoint.ServerEndpoint = @endpoint.endpoint
  .get("/hello/{name}")
  .input(@endpoint.path("name", @schema.string))
  .output(@endpoint.text_out())
  .serve_public(name => Ok("hello, \{name}"))

///|
let app : @router.Router = @router.Router::must([hello])

///|
pub async fn serve_app(addr : String) -> Unit {
  @server.serve(app.handler(), addr~, on_listen=bound => println(bound))
}
```

```mbt nocheck
///|
fn main {
  @mttp_async.run(async fn() { serve_app("127.0.0.1:8080") })
}
```

The repository has runnable examples:
[examples/get](https://github.com/gaato/mttp/tree/main/examples/get) (a
command-line GET),
[examples/serve](https://github.com/gaato/mttp/tree/main/examples/serve) (a
server) and
[examples/fetch](https://github.com/gaato/mttp/tree/main/examples/fetch) (the
same handlers on JavaScript hosts, with a Cloudflare Workers app).

## Tests

Code that takes its Client as a parameter can be tested without the network:
give it a Client over `BackendStub` from `gaato/mttp/testing`, which answers
with canned responses and records what was sent. The test package imports
`gaato/mttp/testing` (`gaato/mttp` in `moon.mod`), and a plain `test` block
runs the async code with `run`, again without importing core/async:

```mbt check
///|
/// Reads a user's name; the Client is a parameter, so a test can pass a stub.
pub async fn user_name(api : @mttp_async.Client, id : Int32) -> String? {
  let user = @mttp_async.get("/users/\{id}").response(
    @mttp_async.as_json_value(),
  )
  match api.send(user).body {
    Ok({ "name": String(name), .. }) => Some(name)
    _ => None
  }
}

///|
test "user_name reads the name from the reply" {
  let stub = @testing.BackendStub::new().when(
    request => request.url == "https://api.example/users/1",
    @testing.Canned::bytes(200, body=b"{\"name\":\"Ada\"}"),
  )
  let api = @mttp_async.Client::new(
    stub,
    @mttp_async.clock(),
    base_url="https://api.example",
  )
  let name : Ref[String?] = Ref(None)
  @mttp_async.run(async fn() { name.val = user_name(api, 1) })
  assert_eq(name.val, Some("Ada"))
  assert_eq(stub.sent().length(), 1)
}
```

Check results after `run`, as above, not inside it. A failing `inspect` or
`assert_eq` inside `run` reports only its error's name, `InspectError`,
without the difference, and `moon test --update` cannot rewrite its
snapshot, because core/async's `run_async_main` prints nothing more of the
error that ends it.

To test a handler, call it: it is an async function from Request to
Response. To test a server end to end, serve it on `127.0.0.1:0` and read
the bound address in `on_listen`.

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
| `gaato/mttp_async` | native, wasm, js | `run`, `client()`, `backend()`, `clock()`, `timer()`, `coordination()`, and re-exports of the types and client functions an app uses |
| `backend` | native, wasm, js | `AsyncBackend`: the HTTP/1.1 engine over TCP and TLS with decompression; the host's `fetch` on js |
| `server` | native, wasm | `serve`: bounded listener, graceful shutdown, background work |
| `files` | native, wasm | `static_files`: a directory's files for GET and HEAD, streamed, with ETag revalidation and paths kept inside the directory |
| `fetch` | js | `fetch_handler`: a handler as a JavaScript `fetch` export |
| `runtime` | native, wasm, js | Clocks, timers, an admission gate and coordination for `gaato/mttp`'s runtime ports |
| `codings` | native, wasm, js | Bounded content codecs, `Decompress` for clients and `compress` for handlers |
| `conn` | native, wasm | TCP and TLS dialing, including CONNECT tunnels |
| `trust` | native, wasm, js | `Trust`: which TLS roots a socket backend accepts |

The module also ships host shims (`hosts/`), JavaScript files that connect a
`fetch` export to Workers, Deno, Bun, Node, Fastly, Vercel and Lambda; they
are not a MoonBit package.

## License

Apache-2.0

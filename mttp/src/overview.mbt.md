# gaato/mttp

HTTP for MoonBit — client, server and WebSockets on native, wasm and JS
hosts. This is the module an app adds: a client with retries, deadlines,
redirects, cookies and decompression on by default, and a server for plain
handlers. See [how it is checked](https://github.com/gaato/mttp#how-it-is-checked).

Typed endpoints, OpenAPI documents, the router and test doubles come from
[`gaato/mttp_core`](https://mooncakes.io/docs/gaato/mttp_core); add it beside
this module when you use them.

## Install

Coming from `moonbitlang/core/async/http` or `moonbitlang/async/http`?
The [migration guide](https://github.com/gaato/mttp/blob/main/MIGRATING.md)
has compiled before and after examples for clients and servers.

```sh
moon add gaato/mttp
```

## Call an API

```mbt check
///|
pub async fn show_user() -> Unit {
  let api = @mttp.client(base_url="https://api.example.com")
  defer api.close()
  let user = @mttp.get("/users/1").response(@mttp.as_json_value())
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
  @mttp.run(show_user)
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
  let api = @mttp.client(base_url="https://api.example.com")
  defer api.close()
  let reply = api.send(
    @mttp.get("/users/\{id}").response(@mttp.as_json_value()),
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
| Decompression | gzip, deflate, br and zstd | per request, by setting `Accept-Encoding`; RFC 9842's dcb and dcz with `@backend.AsyncBackend::new(dictionaries=)` |
| Body size | Buffered bodies up to 64 MiB after decoding | `max_body_bytes=` |
| TLS | The system's roots | `trust=PemFile(..)` |
| Network, clock and timers | The real ones | `backend=`, `clock=`, `timer=`, for tests (see [Tests](#tests)) |
| Observation | None | `observer=` (one `Attempt` per attempt), `events=` (every `ClientEvent`: attempts, connection phases, redirects, retries), `random=` (retry jitter) |

## Cookies

A Client keeps no cookies unless it is given a jar. With `cookies=`, every
response's `Set-Cookie` is stored, and matching cookies are sent with each
request, on every redirect hop too, so a login that answers with a redirect
and a cookie works as in a browser:

```mbt check
///|
/// Logs in, then reads a page that needs the session cookie.
pub async fn account_page(token : String) -> String? {
  let jar = @mttp.CookieJar::new(@mttp.clock())
  let site = @mttp.client(base_url="https://shop.example", cookies=jar)
  defer site.close()
  ignore(site.send(@mttp.post("/login").body_json({ "token": token })))
  site.send(@mttp.get("/account")).body.to_option()
}
```

The jar belongs to the caller: several Clients may share it, and it outlives
them. A Client built with `Client::new` takes one the same way, `cookies=`.
The jar does not apply browsers' `SameSite` rules.

## With an API SDK

An SDK built on `gaato/mttp_core` (such as `gaato/openai` or `gaato/anthropic`)
creates its own Client with the provider's base URL, authentication and retry
rules. Give it the I/O with `backend()`, `clock()` and `timer()`; the timer
lets it enforce its deadlines. `backend()` is the network alone, HTTP/1.1
with decompression; the SDK's Client follows redirects itself, as every
`Client` does:

```mbt nocheck
///|
let claude = @anthropic.Anthropic::new(
  api_key~,
  @mttp.backend(),
  @mttp.clock(),
  timer=@mttp.timer(),
)
```

The app's `moon.mod` lists the SDK and `gaato/mttp`.

## Serve

`gaato/mttp/server` serves any `async (Request) -> Response` handler on
native and wasm, with bounded connections, headers and bodies and a graceful
shutdown:

```mbt nocheck
@server.serve(request => @mttp.Response::new(200), addr="127.0.0.1:8080")
```

A request body arrives as a stream. `Body::read_all(max~)` reads it into
memory and refuses more than `max` bytes:

```mbt check
///|
/// Echoes a request body of up to 64 KiB; a larger one gets 413.
pub async fn echo(request : @mttp.Request) -> @mttp.Response noraise {
  let body = request.body.read_all(max=65536) catch {
    TransportError(kind=TooLarge(..), ..) => return @mttp.Response::new(413)
    _ => return @mttp.Response::new(400)
  }
  @mttp.Response::new(200, body=Bytes(body))
}
```

The server binds with `SO_REUSEADDR`, as Go's and Node's servers do, so a
restarted process can listen again while the old one's connections wait out
TIME-WAIT. On Linux a second server still cannot take a port that is being
listened on; on macOS and the BSDs a bind to a specific address can coexist
with an earlier wildcard bind of the same port.

An app with forms and a cookie session adds the router's `same_origin`
middleware, which refuses state-changing requests from other sites, and sets
its cookies `SameSite`. On JavaScript hosts, `gaato/mttp/fetch` turns
the same handler into a `fetch` export for Cloudflare Workers, Deno, Bun,
Node, Fastly, Vercel and AWS Lambda. `gaato/mttp/files` serves a
directory's files, such as stylesheets and scripts, as one more handler,
alone or behind a Router's 404s.

## A complete app

A typed endpoint validates its request and documents itself for OpenAPI; a
Router serves a set of them as one handler. They come from `gaato/mttp_core`, so
the app's `moon.mod` lists both modules (`moon add gaato/mttp_core`), and its
`moon.pkg` imports what it uses:

```text
import {
  "gaato/mttp",
  "gaato/mttp/server",
  "gaato/mttp_core/endpoint",
  "gaato/mttp_core/router",
  "gaato/mttp_core/schema",
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
  @mttp.run(async fn() { serve_app("127.0.0.1:8080") })
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
give it the app's own `client()` over `BackendStub` from `gaato/mttp_core/testing`,
which answers with canned responses and records what was sent. `backend=`
replaces only the network, so the Client keeps every default above:
retries, deadlines, redirects and cookies. The test package imports
`gaato/mttp_core/testing` (`gaato/mttp_core` in `moon.mod`), and a plain `test` block
runs the async code with `run`, again without importing core/async:

```mbt check
///|
/// Reads a user's name; the Client is a parameter, so a test can pass a stub.
pub async fn user_name(api : @mttp.Client, id : Int32) -> String? {
  let user = @mttp.get("/users/\{id}").response(@mttp.as_json_value())
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
  let api = @mttp.client(base_url="https://api.example", backend=stub)
  let name : Ref[String?] = Ref(None)
  @mttp.run(async fn() { name.val = user_name(api, 1) })
  assert_eq(name.val, Some("Ada"))
  assert_eq(stub.sent().length(), 1)
}
```

A test of retries or deadlines also passes `clock=` a virtual clock, such as
`VirtualClock` from `gaato/mttp/runtime`; the Client's timers then run
on it too, so 30 s pass without waiting.

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
which decides protocol versions, proxies, pooling and decompression itself.
The native/wasm engine speaks HTTP/1.1; an HTTP/2 engine awaits ALPN in
core/tls. JS servers use their host's protocols. WebSocket clients use
the host's WebSocket API on JS; fetch upgrades are available on Workers,
Deno and Bun. See the [host matrix](https://github.com/gaato/mttp/blob/main/mttp/hosts/README.md#websockets).
wasm-gc has no runtime here; use `gaato/mttp_core` there and provide its
runtime ports.

## Packages

| Package | Targets | Purpose |
|---|---|---|
| `gaato/mttp` | native, wasm, js | `run`, `client()`, `backend()`, `clock()`, `timer()`, `coordination()`, and re-exports of the types and client functions an app uses |
| `backend` | native, wasm, js | `AsyncBackend`: the HTTP/1.1 engine over TCP and TLS with decompression; the host's `fetch` on js |
| `server` | native, wasm | `serve`: bounded listener, graceful shutdown, background work |
| `ws` | native, wasm, js | WebSocket connect, upgrade and typed connectors; opt-in permessage-deflate on native/wasm, host-managed compression on JS |
| `files` | native, wasm | `static_files`: streamed GET/HEAD, ETags and paths kept inside the directory; `ranges=true` adds preconditions and Range 206/416 |
| `fetch` | js | `fetch_handler`: a handler as a JavaScript `fetch` export |
| `runtime` | native, wasm, js | Clocks, timers, an admission gate and coordination for `gaato/mttp_core`'s runtime ports |
| `codings` | native, wasm, js | Bounded content codecs, `Decompress`, opt-in `CompressRequests` and `compress` for handlers |
| `conn` | native, wasm | TCP and TLS dialing, including CONNECT tunnels |
| `trust` | native, wasm, js | `Trust`: which TLS roots a socket backend accepts |

The root re-exports what an app uses from
[`gaato/mttp_core`](https://mooncakes.io/docs/gaato/mttp_core), the part
of the family without I/O: the messages (`Request`, `Response`, `Body`,
`Headers`, `Method`, `Url`), `Handler`, request attributes such as
`remote_addr` and `background`, streamed bodies, `Backend`, errors, and
the client API (`Client`, `get`, `as_json` and the rest). Add
`gaato/mttp_core` for what it does not re-export: typed endpoints, the router
and OpenAPI documents, server-sent events, rate limits such as
`WindowLimiter`, the test doubles of `gaato/mttp_core/testing`, and these
portable packages:

- `ws`: sessions, messages and limits shared by the network and in-process adapters.
- `client/httpcache`: an opt-in RFC 9111 private cache with Vary, revalidation and bounded memory.
- `representation`: media negotiation, validators, preconditions and byte-range selection.
- `apispec/diff`: structural OpenAPI compatibility reports from client and server viewpoints.
- `multipart`: streamed form-data writing and bounded reading, including typed endpoint inputs.
- `router`: dispatch, CORS and middleware such as `rate_limit` with RateLimit headers, `secure_headers` and signed-cookie `sessions`.

The module also ships host shims (`hosts/`), JavaScript files that connect a
`fetch` export to Workers, Deno, Bun, Node, Fastly, Vercel and Lambda; they
are not a MoonBit package.

## Libraries and earlier names

Writing a library, such as an SDK for some API? Depend on `gaato/mttp_core`
only: it has the same types and client without any I/O, so it builds on
every target, wasm-gc included, and the app chooses how requests are sent.

Coming from `gaato/mttp_async`? It is this module, renamed in 0.3; up to
0.2, `gaato/mttp` was the part without I/O, now `gaato/mttp_core`. The
[changelog](https://github.com/gaato/mttp/blob/main/mttp/CHANGELOG.md) has
a table of what to replace.

## License

Apache-2.0

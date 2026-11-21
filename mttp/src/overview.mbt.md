# gaato/mttp

An HTTP client and server for MoonBit apps on native, wasm (under moonrun)
and JavaScript hosts.

- **Client.** `client()` retries transient failures within a budget, enforces
  a deadline per attempt and per call, follows redirects without downgrading
  to HTTP, decodes gzip, deflate, Brotli and Zstandard, and keeps cookies
  when given a jar. A 404 is a value in the reply; a network failure is a
  typed error that says in which phase it happened and whether the request
  was sent.
- **Server.** Any `async (Request) -> Response` function is a handler. The
  server bounds connections, heads and bodies and shuts down gracefully.
  Static files, response compression, WebSockets, and a `fetch` export for
  Cloudflare Workers, Deno, Bun, Node and other JavaScript hosts come in
  the same module.
- **Tests.** Swap the network for a stub and the clock for a virtual one;
  the client keeps every default.

Writing a library, such as an SDK for some API, rather than an app? Depend on
[`gaato/mttp_core`](https://mooncakes.io/docs/gaato/mttp_core) instead: it
has the same types and client without any I/O. Typed endpoints, the router
and OpenAPI documents also live there.

The HTTP/1 codec is checked against llhttp's tests, WebSockets against
Autobahn, and the client and server against other implementations such as
nginx, curl, Go and Node:
[how it is checked](https://github.com/gaato/mttp#how-it-is-checked).

## Install

```sh
moon add gaato/mttp
```

Then import `"gaato/mttp"` in the `moon.pkg` of the package that uses it.

## Call an API

```mbt check
///|
#derive(FromJson)
struct User {
  name : String
}

///|
/// Prints a user's name, the HTTP failure, or the network failure.
pub async fn show_user(id : Int32) -> Unit {
  let api = @mttp.client(base_url="https://api.example.com")
  defer api.close()
  let request = @mttp.get("/users/\{id}").response(@mttp.as_json())
  let reply = api.send(request) catch {
    error => {
      println("network: \{error}")
      return
    }
  }
  let user : Result[User, _] = reply.body
  match user {
    Ok(user) => println(user.name)
    Err(failure) => println("HTTP \{reply.status}: \{failure}")
  }
}
```

An executable starts it with `run`, which needs no import of
`moonbitlang/core/async` and no experimental opt-in in `moon.pkg`:

```mbt nocheck
///|
fn main {
  @mttp.run(async fn() { show_user(1) })
}
```

Reuse one Client for many calls: it pools connections and shares the retry
budget. Close it when done.

`get`, `post` and `request` build a request; `.header`, `.bearer`,
`.body_json` and `.body_bytes` add to it. For other methods, pass a
`Request` to `request`:

```mbt check
///|
/// Renames a user with PATCH; true when the server answered 2xx.
pub async fn rename_user(
  api : @mttp.Client,
  id : Int32,
  name : String,
  token : String,
) -> Bool {
  let request = @mttp.request(@mttp.Request::patch("/users/\{id}"))
    .bearer(token)
    .body_json({ "name": name })
  api.send(request).body is Ok(_)
}
```

`.response` chooses how the reply is read: `as_string` (the default),
`as_bytes`, `as_json`, `as_json_value`, or, without buffering, `as_lines`
for each line and `as_sse` for server-sent events. With every one of them, a
final status outside 2xx is `Err(UnexpectedStatus(..))` in `reply.body`, and
JSON that does not decode is `Err(Deserialization(..))`; both carry the
response head and an excerpt of the body. Network failures, expired
deadlines, refused redirects and bodies over the limit are raised by `send`
as a `TransportError(kind~, phase~, detail~)`; its `is_unsent()` is true
only when the request provably never reached the server.

`api.sse_reconnecting(@mttp.Request::get(url), on_event)` reconnects an
event stream when it drops and resumes from its last event ID. To read a
large body in chunks, `as_stream` comes from `gaato/mttp_core/client`.

## What `client()` does by default

| | Default | Change it with |
|---|---|---|
| Retries | Up to two. For GET, PUT, DELETE and other idempotent requests: on 408, 409, 429, 500, 502, 503 and 504 and on network failures. For any request, POST included: when it was never sent. `Retry-After` is honoured, and a server that asks to wait more than 60 s is not retried. Otherwise the wait starts at 500 ms and doubles, with jitter | `retry=@mttp.RetryPolicy::none()`, or a policy of your own |
| Retry budget | Retries stay within 20 % of the requests of the last 10 s, plus 10 per second, so a failing server is not flooded | `retry_budget=@mttp.RetryBudget::new(..)` or `@mttp.RetryBudget::unlimited()` |
| Deadlines | 30 s for each attempt, 120 s for the whole call, retries and their waits included | `timeout_ms=`, `total_ms=`, or `.timeout_ms(..)` on one request |
| Redirects | Up to 10 hops, never from HTTPS to HTTP. `Authorization`, `Proxy-Authorization` and `Cookie` are dropped when the origin changes, except from `http` on port 80 to `https` on port 443 of the same host | `redirect=@mttp.RedirectConfig::none()`, or `.follow_redirects(false)` on one request |
| Cookies | None kept | `cookies=@mttp.CookieJar::new(@mttp.clock())`; the jar belongs to the caller and can be shared between Clients |
| Decompression | gzip, deflate, br and zstd on native and wasm | On native and wasm, a request that sets `Accept-Encoding` gets its body as sent |
| Body size | Buffered bodies up to 64 MiB after decoding | `max_body_bytes=`, or `.max_body_bytes(..)` on one request |
| Proxies | `http_proxy`, `https_proxy`, `all_proxy` and `no_proxy` from the environment, on native and wasm; `http://`, `https://` and `socks5h://` proxies | `config=` a `ClientConfig` from `gaato/mttp_core/h1client` |
| TLS roots | The system's | `trust=PemFile("roots.pem")` |
| Admission | Every request at once | `limiter=` a `RateLimiter` from `gaato/mttp_core/client` |
| Observation | None | `observer=` gets one `Attempt` per attempt; `events=` gets every `ClientEvent`: attempts, connection phases, redirects and retries |
| Network and time | The real network, clock and timers | `backend=`, `clock=`, `timer=` (see [Tests](#tests)) |

A type from a `gaato/mttp_core/...` package needs `moon add gaato/mttp_core`
as well.

On JavaScript the client sends through the host's `fetch`, which chooses
the protocol, pooling, proxies, decompression and TLS roots itself. The
Client still applies its retries, deadlines, redirects and cookie jar, but
a browser's `fetch` hides redirect responses, which the Client then raises
as an error, and may hide `Set-Cookie`.

`Client::new`, which builds a Client over a backend you supply, starts with
no retries and no deadlines; redirects, the retry budget and the 64 MiB
limit still apply.

## Serve

A handler is an `async (Request) -> Response noraise` function. The request
carries `meth`, `url` and `headers` as fields. Its body arrives as a stream;
`read_all(max~)` returns the bytes exactly as sent and refuses more than
`max`. Import `"gaato/mttp/server"` to listen on native or wasm:

```mbt check
///|
/// Echoes a request body of up to 64 KiB with its content type; a larger
/// body gets 413.
pub async fn echo(request : @mttp.Request) -> @mttp.Response noraise {
  let body = request.body.read_all(max=65536) catch {
    TransportError(kind=TooLarge(..), ..) => return @mttp.Response::new(413)
    _ => return @mttp.Response::new(400)
  }
  let content_type = request.headers
    .get("content-type")
    .unwrap_or("application/octet-stream")
  @mttp.Response::new(
    200,
    headers=@mttp.Headers::of([("content-type", content_type)]),
    body=Bytes(body),
  )
}

///|
pub async fn serve_echo() -> Unit {
  @server.serve(echo, addr="127.0.0.1:8080", on_listen=addr => {
    println("listening on \{addr}")
  })
}
```

By default the server takes 256 connections at once, request heads up to
16 KiB and bodies up to 1 MiB, and gives a client 5 s to send a head and
5 s for a body. When its task is cancelled it stops accepting, lets running
responses finish for up to 10 s, then cancels them. `limits=` takes a
`ServerLimits` from `gaato/mttp_core/h1server` (add `gaato/mttp_core` to use
it).

The other packages of the module serve and connect in more ways:

| Package | Targets | What it adds |
|---|---|---|
| `gaato/mttp/files` | native, wasm | `static_files(dir)`: a directory as a handler, with ETags and 304s; hidden files and paths outside the directory are 404s; `ranges=true` answers single byte ranges |
| `gaato/mttp/codings` | native, wasm, js | `compress(handler)` negotiates zstd, br, gzip or deflate for responses; `CompressRequests` compresses request bodies; RFC 9842 compression dictionaries for both ends |
| `gaato/mttp/ws` | native, wasm, js | WebSocket `connect` and `upgrade`, with opt-in permessage-deflate on native and wasm |
| `gaato/mttp/fetch` | js | `fetch_handler(handler)`: the same handler as a `fetch` export for Cloudflare Workers, Deno, Bun, Node, Fastly, Vercel and AWS Lambda |
| `gaato/mttp/runtime` | native, wasm, js | `VirtualClock` for tests, and the clocks and timers behind `clock()` and `timer()` |
| `gaato/mttp/backend` | native, wasm, js | `AsyncBackend`: the network alone, for a Client built by hand |
| `gaato/mttp/trust` | native, wasm, js | `Trust`: which TLS roots a socket connection accepts |
| `gaato/mttp/conn` | native, wasm | `TcpDialer`: TCP connections, and TLS over any connection, such as one through a CONNECT tunnel |

The JavaScript files that connect a `fetch` export to each host ship in the
module's `hosts/` directory; the
[host guide](https://github.com/gaato/mttp/blob/main/mttp/hosts/README.md)
shows how to use them and which hosts accept WebSocket upgrades.

## Typed endpoints

An endpoint from `gaato/mttp_core` validates its input, serves requests and
describes itself for OpenAPI; a Router serves a set of them as one handler.
Add the second module with `moon add gaato/mttp_core` and import what the
package uses:

```text
import {
  "gaato/mttp",
  "gaato/mttp/server",
  "gaato/mttp_core/endpoint",
  "gaato/mttp_core/router",
  "gaato/mttp_core/schema",
}
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
/// The app's endpoints, with the clock and timer a Client's deadlines need
/// when it calls the Router in memory.
fn hello_app() -> @router.Router {
  @router.Router::must([hello], clock=@mttp.clock(), timer=@mttp.timer())
}

///|
pub async fn serve_hello(addr : String) -> Unit {
  @server.serve(hello_app().handler(), addr~)
}
```

A Router is also a backend: `@mttp.client(backend=hello_app())` calls the
endpoints in memory, without a port, which suits tests. A Router built
without `clock` and `timer` refuses calls that carry a deadline, as every
call from `client()` does.

## Tests

Code that takes its Client as a parameter can be tested without the
network. Give it a `client()` over `BackendStub` from
`gaato/mttp_core/testing`, which answers with canned responses and records
what was sent. `backend=` replaces only the network, so the Client keeps
every default above. A plain `test` block runs the async code with `run`:

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

Check results after `run`, as above: a failing `assert_eq` inside `run`
ends the whole test executable, so the package's remaining tests do not
run. To test retries and deadlines without waiting, also pass `clock=` a
`VirtualClock` from `gaato/mttp/runtime`; the Client's timers then run on
it. To test a handler, call it with a `Request`.

## With a library built on mttp_core

A library that takes a backend, a clock and a timer gets the real ones from
`@mttp.backend()`, `@mttp.clock()` and `@mttp.timer()`. The library keeps
its own base URL, authentication and retry rules; the backend supplies only
the network.

## Related modules

| Need | Module |
|---|---|
| HTTP Digest authentication | [`gaato/mttp_digest`](https://mooncakes.io/docs/gaato/mttp_digest) |
| JSON codecs and schemas generated from annotated types | [`gaato/mttp_schemagen`](https://mooncakes.io/docs/gaato/mttp_schemagen) |
| An httpx/requests-style calling surface over mttp | [`gaato/requesto`](https://mooncakes.io/docs/gaato/requesto) |
| The compressors behind decompression and `codings`, for use on their own | [`gaato/deflate`](https://mooncakes.io/docs/gaato/deflate), [`gaato/brotli`](https://mooncakes.io/docs/gaato/brotli), [`gaato/zstd`](https://mooncakes.io/docs/gaato/zstd) |

## When something else fits better

- **One request in a script.** `moonbitlang/core/async/http`'s
  `@http.get(url)` needs no dependency. mttp is for what grows around that
  call; [a side-by-side table](https://github.com/gaato/mttp#beside-moonbitlangcoreasynchttp)
  and a [migration guide](https://github.com/gaato/mttp/blob/main/MIGRATING.md)
  compare the two.
- **HTTP/2 or HTTP/3.** On native and wasm mttp speaks HTTP/1.1. On
  JavaScript the host's `fetch` and server choose the version.
- **1xx responses or trailers.** The client skips informational responses
  and does not expose trailers.
- **wasm-gc.** This module has no runtime there; `gaato/mttp_core` builds on
  wasm-gc, and you supply its I/O.

Before 1.0, a minor release may change the API; the
[changelog](https://github.com/gaato/mttp/blob/main/mttp/CHANGELOG.md) says how
to update.

## License

[Apache-2.0](https://github.com/gaato/mttp/blob/main/LICENSE)

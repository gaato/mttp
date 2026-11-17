# Migrating from `moonbitlang/core/async/http`

This guide compares the HTTP package shipped with MoonBit
`0.10.21+06da1ed44`, the toolchain pinned by this repository's
[moonbit-version](moonbit-version), with `gaato/mttp`. The before and after
files are compiled together in [examples/migrate](examples/migrate).
They use separate function names so you can keep both versions open.

## Choose the module

For an app on native, wasm or js, add `gaato/mttp`:

```sh
moon add gaato/mttp
```

Import `gaato/mttp` in `moon.pkg`; add `gaato/mttp/server` for the socket
server on native or wasm. Start an async function with `@mttp.run` from
`fn main`, or keep your existing async entry point. mttp uses core/async's
runtime; ordinary client and handler code needs no direct experimental
core/async imports. Keep those imports and their opt-ins if you use task
groups or other runtime operations yourself.

For a library or wasm-gc program, depend on `gaato/mttp_core` and supply its
runtime ports, including a `Backend`, clock and timer. It contains no I/O.
An app also adds that module when it needs typed endpoints, the router or
OpenAPI, which the `gaato/mttp` root does not re-export.

The examples' [moon.pkg](examples/migrate/moon.pkg) lists both sets of
imports and the experimental opt-ins needed only by the before code and
the local test runner. The module targets native so both socket servers can
run together. The after client APIs also build on wasm and js; on js, the
host's `fetch` owns TLS, decompression and connection reuse. wasm-gc needs
the core module and an application-provided backend.

## Client

### GET, text and JSON

Before, `get` returns a header and an already buffered `MessageBody`.
Call `text()` or `json()` to decode it:

<!-- source: examples/migrate/get_before.mbt -->
```mbt
///|
pub async fn get_before(base : String) -> (String, Json) {
  let (_, text) = @http.get(base + "/hello")
  let (_, json) = @http.get(base + "/json")
  (text.text(), json.json())
}
```

After, a request plan selects its decoder. `get` selects text by default;
`as_json_value()` selects `Json`, and `as_json()` uses `FromJson` for the
type inferred from its context.
These small examples unwrap successful results; handle failures as shown
below in an app:

<!-- source: examples/migrate/get_after.mbt -->
```mbt
///|
pub async fn get_after(base : String) -> (String, Json) {
  let api = @mttp.client(base_url=base)
  defer api.close()
  let text = api.send(@mttp.get("/hello")).body.unwrap()
  let json = api.send(@mttp.get("/json").response(@mttp.as_json_value())).body.unwrap()
  (text, json)
}
```

Text decoding also changes: core's `MessageBody::text()` rejects invalid
UTF-8; mttp's `as_string()` replaces invalid sequences. If rejection matters,
select `as_bytes()` and decode with `moonbitlang/core/encoding/utf8.decode`
yourself, or supply a custom response plan.

### POST with JSON and headers

Before, supply the content type along with the serialized JSON:

<!-- source: examples/migrate/post_before.mbt -->
```mbt
///|
pub async fn post_before(base : String) -> String {
  let (_, body) = @http.post_json(base + "/echo", { "name": "Ada" }, headers={
    "Content-Type": "application/json",
    "X-Request-Id": "demo",
  })
  body.text()
}
```

After, `body_json` sets `Content-Type: application/json`. Header names are
strings; mttp's `Headers` preserves repeated fields rather than storing one
value per case-insensitive map key:

<!-- source: examples/migrate/post_after.mbt -->
```mbt
///|
pub async fn post_after(base : String) -> String {
  let api = @mttp.client(base_url=base)
  defer api.close()
  api.send(
    @mttp.post("/echo")
    .body_json({ "name": "Ada" })
    .header("X-Request-Id", "demo"),
  ).body.unwrap()
}
```

### Timeouts

Before, wrap the operation in core/async's timeout:

<!-- source: examples/migrate/timeout_before.mbt -->
```mbt
///|
pub async fn timeout_before(base : String) -> String {
  @async.with_timeout(1000, () => {
    let (_, body) = @http.get(base + "/hello")
    body.text()
  })
}
```

After, set an attempt deadline and a total call budget, including retry
waits. A request can override the attempt deadline. This pair illustrates
configuration, not identical budgets: the before has one 1000 ms timeout;
the after has up to 3000 ms overall and 500 ms per attempt:

<!-- source: examples/migrate/timeout_after.mbt -->
```mbt
///|
pub async fn timeout_after(base : String) -> String {
  let api = @mttp.client(base_url=base, timeout_ms=1000, total_ms=3000)
  defer api.close()
  api.send(@mttp.get("/hello").timeout_ms(500)).body.unwrap()
}
```

`client()` defaults to 30 seconds per attempt and 120 seconds overall.
For a long download or event stream, choose budgets that fit the operation;
streaming does not remove deadlines.

### Reuse a client

Before, `Client` shares headers but `Client::request_stream` connects for
each request, and `Client::close` is empty in this toolchain. A low-level
`ClientConnection` can be reused manually after consuming the previous
response; that is distinct from a pool:

<!-- source: examples/migrate/reuse_before.mbt -->
```mbt
///|
pub async fn reuse_before(base : String) -> String {
  let api = @http.Client(headers={ "X-Request-Id": "demo" })
  defer api.close()
  let (_, first) = api.get(base + "/hello")
  let (_, second) = api.get(base + "/hello")
  first.text() + ", " + second.text()
}
```

After, retain one Client for related calls and close it at the owner's
shutdown. Its native/wasm backend pools connections; `config=` tunes the
pool. Creating and closing one Client per call loses that reuse:

<!-- source: examples/migrate/reuse_after.mbt -->
```mbt
///|
pub async fn reuse_after(base : String) -> String {
  let api = @mttp.client(
    base_url=base,
    headers=@mttp.Headers::of([("X-Request-Id", "demo")]),
  )
  defer api.close()
  let first = api.send(@mttp.get("/hello")).body.unwrap()
  let second = api.send(@mttp.get("/hello")).body.unwrap()
  first + ", " + second
}
```

### Errors and HTTP statuses

Before, a 404 is a normal `ResponseHeader.code`. Connection, protocol and
decoding errors are raised:

<!-- source: examples/migrate/errors_before.mbt -->
```mbt
///|
pub async fn errors_before(base : String) -> String {
  let (head, body) = @http.get(base + "/missing") catch {
    @http.UriParseError::_ => return "invalid URL"
    _ => return "request failed"
  }
  if head.code == 404 {
    "missing"
  } else {
    body.text()
  }
}
```

After, there are two paths. Transport failures are raised as `TransportError`,
with a `Kind` and a `Phase`; HTTP and decoding failures are values in
`reply.body`. A standard decoder accepts 2xx, returning
`Err(UnexpectedStatus(head, body=...))` for other statuses and
`Err(Deserialization(...))` for decoding failures. `reply.status` and
`reply.headers` remain available:

<!-- source: examples/migrate/errors_after.mbt -->
```mbt
///|
pub async fn errors_after(base : String) -> String {
  let api = @mttp.client(base_url=base)
  defer api.close()
  let reply = api.send(@mttp.get("/missing")) catch {
    @mttp.TransportError::TransportError(kind=Timeout(..), phase~, ..) =>
      return "timeout during \{Repr(phase)}"
    @mttp.TransportError::TransportError(..) as error => return error.message()
    error => raise error
  }
  match reply.body {
    Ok(text) => text
    Err(UnexpectedStatus(head, ..)) if head.status == 404 => "missing"
    Err(failure) => failure.to_string()
  }
}
```

Use `as_string().any_status()` or the corresponding decoder's `any_status()`
to preserve core's status handling. The local runner checks that a 404 then
has `status == 404` and `body == Ok("")`. The raw `Backend` response also
keeps status separate from transport failure.

There is no one-to-one conversion of core exceptions: mttp implements its
own HTTP framing and wraps socket I/O. In the socket backend, TCP/name
resolution failures become `Connect` in `Dial`; invalid request configuration
can be `Invalid` in `Pool`; body limit failures are `TooLarge` in `Body`.
`Timeout` includes the configured milliseconds. Phases also include `Write`
and `Head`. Match the fields your recovery needs and keep a fallback for
the non-exhaustive enums. `is_unsent()` reports whether it is known that the
origin did not act on the request; a write failure alone is no such proof.

### Stream a large response

Before, keep the connection alive while pulling chunks, then close it:

<!-- source: examples/migrate/stream_before.mbt -->
```mbt
///|
pub async fn stream_before(base : String) -> Int64 {
  let (_, conn) = @http.get_stream(base + "/stream")
  defer conn.close()
  let mut size = 0L
  while conn.read() is Some(chunk) {
    size += chunk.length().to_int64()
  }
  size
}
```

After, consume the stream inside `ResponsePlan::stream`. The Client owns
cleanup and closes it on return or failure. Do not store the stream for
later. Once the callback starts, the Client does not retry the operation:

<!-- source: examples/migrate/stream_after.mbt -->
```mbt
///|
pub async fn stream_after(base : String) -> Int64 {
  let api = @mttp.client(base_url=base)
  defer api.close()
  api.send(
    @mttp.get("/stream").response(
      @mttp.ResponsePlan::stream((_, body, _) => {
        let mut size = 0L
        while body.read_some() is Some(chunk) {
          size += chunk.length().to_int64()
        }
        size
      }),
    ),
  ).body.unwrap()
}
```

Buffered decoding has a 64 MiB default limit after decompression;
`max_body_bytes=` or the request's `max_body_bytes` changes it. A raw stream
consumer chooses its own cumulative limit; the third callback argument is
the configured limit if it needs to buffer. This counter stores no body.
For line or SSE processing, `as_lines` and `as_sse` provide bounded records.

### TLS and trust

Both socket clients use system trust roots by default. Before, custom trust
is an option on the low-level connection, not on `@http.get`:

<!-- source: examples/migrate/tls_before.mbt -->
```mbt
///|
pub async fn tls_before(origin : String, pem : String) -> Bytes {
  let conn = @http.ClientConnection(origin, trust=CustomPemFile(pem))
  defer conn.close()
  conn.request(Get, "/")
  ignore(conn.end_request())
  conn.read_all()
}
```

After, give the Client the PEM file. This example accepts any HTTP status
to match the before version:

<!-- source: examples/migrate/tls_after.mbt -->
```mbt
///|
pub async fn tls_after(origin : String, pem : String) -> Bytes {
  let api = @mttp.client(base_url=origin, trust=PemFile(pem))
  defer api.close()
  api.send(@mttp.get("/").response(@mttp.as_bytes().any_status())).body.unwrap()
}
```

The PEM examples are compiled but not executed by the local runner. On js,
custom socket trust is not available: the host's `fetch` controls trust.
For inbound HTTPS, terminate TLS ahead of `server.serve`, whose listener is
plain TCP, or implement a TLS adapter over the lower-level connection ports.

## Server

### Return a response from a handler

Before, write the head and body to `ServerConnection`; `run_forever` ends
the response after the callback returns if you have not ended it yourself:

<!-- source: examples/migrate/handler_before.mbt -->
```mbt
///|
async fn handler_before(conn : @http.ServerConnection) -> Unit {
  conn.send_response(200, "OK")
  conn.write(b"hello")
}
```

After, return a Response. A synchronous function can be called from the
async Handler when it does no I/O; the server owns framing and sending.
Handlers cannot raise unhandled errors, so translate failures to responses:

<!-- source: examples/migrate/handler_after.mbt -->
```mbt
///|
pub fn handler_after(_ : @mttp.Request) -> @mttp.Response {
  @mttp.Response::new(200, body=Bytes(b"hello"))
}
```

### Route a request

Before, dispatch on the request method and target:

<!-- source: examples/migrate/routing_before.mbt -->
```mbt
///|
async fn routing_before(
  request : @http.RequestHeader,
  conn : @http.ServerConnection,
) -> Unit {
  match (request.meth, request.path) {
    (Get, "/hello") => handler_before(conn)
    (Get, "/json") => {
      conn.send_response(200, "OK")
      conn.write(b"{\"name\":\"Ada\"}")
    }
    (Post, "/echo") => body_before(conn)
    (Get, "/stream") => response_stream_before(conn)
    _ => conn.send_response(404, "Not Found")
  }
}
```

After, a plain Handler can dispatch the same way. The socket server supplies
an absolute `request.url`; parse it and use `path` so the query and origin
do not become part of route matching:

<!-- source: examples/migrate/routing_after.mbt -->
```mbt
///|
pub fn routing_after() -> @mttp.Handler {
  request => {
    let url = @mttp.Url::parse(request.url) catch {
      _ => return @mttp.Response::new(400)
    }
    match (request.meth, url.path) {
      (Get, "/hello") => handler_after(request)
      (Get, "/json") =>
        @mttp.Response::new(200, body=Bytes(b"{\"name\":\"Ada\"}"))
      (Post, "/echo") => body_after(request)
      (Get, "/stream") => response_stream_after(request)
      _ => @mttp.Response::new(404)
    }
  }
}
```

For route parameters and validated inputs, use `gaato/mttp_core/endpoint`
with `gaato/mttp_core/router`. One endpoint definition also supplies its
typed client call and OpenAPI document; [examples/tour](examples/tour)
shows that complete path. The manual dispatcher above deliberately has no
parameter or query decoding policy.

### Read a body with a limit

Before, enforce the limit while accumulating chunks. Calling `read_all()`
first would allocate the entire body before checking its size:

<!-- source: examples/migrate/body_before.mbt -->
```mbt
///|
async fn body_before(conn : @http.ServerConnection) -> Unit {
  let buffer = @buffer.Buffer()
  while conn.read() is Some(chunk) {
    if chunk.length() > 65536 - buffer.length() {
      conn.send_response(413, "Content Too Large")
      return
    }
    buffer.write_bytes(chunk)
  }
  conn.send_response(200, "OK")
  conn.write(buffer.to_bytes())
}
```

After, `Body::read_all(max=...)` refuses an oversized body and closes its
stream on every exit. The listener also applies its own request body bound
(1 MiB by default); the smaller handler limit here is 64 KiB:

<!-- source: examples/migrate/body_after.mbt -->
```mbt
///|
pub async fn body_after(request : @mttp.Request) -> @mttp.Response noraise {
  let body = request.body.read_all(max=65536) catch {
    TransportError(kind=TooLarge(..), ..) => return @mttp.Response::new(413)
    _ => return @mttp.Response::new(400)
  }
  @mttp.Response::new(200, body=Bytes(body))
}
```

### Stream a response

Before, write successive chunks and flush when data should be sent now:

<!-- source: examples/migrate/response_stream_before.mbt -->
```mbt
///|
async fn response_stream_before(conn : @http.ServerConnection) -> Unit {
  conn.send_response(200, "OK")
  conn.write(b"one\n")
  conn.flush_partial_data()
  conn.write(b"two\n")
}
```

After, return a `StreamBody` implementing `BodyStream`. Each pull returns a
nonempty chunk or permanent EOF; `close` releases resources and makes later
reads return EOF. The server pulls it and chooses the HTTP framing:

<!-- source: examples/migrate/response_stream_after.mbt -->
```mbt
///|
priv struct Chunks {
  mut index : Int32
}

///|
impl @mttp.BodyStream for Chunks with fn read_some(self) {
  let chunk = match self.index {
    0 => Some(b"one\n")
    1 => Some(b"two\n")
    _ => None
  }
  if self.index < 2 {
    self.index += 1
  }
  chunk
}

///|
impl @mttp.BodyStream for Chunks with fn close(self) {
  self.index = 2
}

///|
pub fn response_stream_after(_ : @mttp.Request) -> @mttp.Response {
  @mttp.Response::new(
    200,
    body=Stream(@mttp.StreamBody::new(Chunks::{ index: 0, })),
  )
}
```

These two fixed chunks stand in for a file or producer. A stream is consumed
once; a streaming request body also cannot be replayed after it has been
taken, so retries and 307/308 redirects need a replayable body.

### Stop and drain

Before, cancellation of `run_forever` closes its server and connections.
This wrapper exposes the bound address to the runner; it adds no drain
period. A core application wanting graceful shutdown must coordinate
admission and in-flight work itself:

<!-- source: examples/migrate/shutdown_before.mbt -->
```mbt
///|
pub async fn shutdown_before(
  addr : String,
  on_listen : (String) -> Unit,
) -> Unit {
  let listener = @http.Server(@socket.Addr::parse(addr))
  defer listener.close()
  on_listen(listener.addr.to_string())
  listener.run_forever(routing_before)
}
```

After, cancellation of `serve` stops admission, closes idle connections,
lets active exchanges and background jobs finish for `limits.drain_ms`
(10 seconds by default), then cancels and joins the remainder:

<!-- source: examples/migrate/shutdown_after.mbt -->
```mbt
///|
pub async fn shutdown_after(
  addr : String,
  on_listen : (String) -> Unit,
) -> Unit {
  @server.serve(routing_after(), addr~, on_listen~)
}
```

Run `serve` in a task group and cancel that task when your shutdown signal
arrives. The example runner uses `group.return_immediately()` after its
requests finish, which cancels the serving work. It checks normal shutdown,
not the timing of an active drain. `limits=` accepts a record update of
`gaato/mttp_core/h1server.ServerLimits::default()` for different bounds.

## Defaults that change behavior

| Choice | Difference and reason |
|---|---|
| Retries | `client()` uses `RetryPolicy::conservative()`: up to two retries for eligible idempotent calls or requests known unsent, to recover from transient failure. `RetryPolicy::none()` disables them. `Client::new` instead defaults to no retries, so libraries choose their policy. |
| Retry budget | A rolling budget limits retry traffic (20% plus 10 per second over 10 seconds), so an outage does not multiply load without bound. |
| Redirects | Core's native/wasm request returns the redirect; its js fetch follows host defaults. mttp follows up to 10 hops, refuses HTTPS-to-HTTP downgrade and strips credentials across origins to avoid forwarding secrets. Use `RedirectConfig::none()` or `follow_redirects(false)` to keep the redirect response. |
| Deadlines and bodies | mttp bounds time and buffered bytes to keep stalled or oversized responses from using resources indefinitely. Streaming consumers still choose their own cumulative size policy. |
| Server bounds | The default is 256 connections, 16 KiB heads, 1 MiB request bodies and 5-second head/body budgets; these bound resource use before a handler can reject a request. Handler execution itself has no deadline unless configured. |
| Date | Core's response sender does not add Date. mttp adds it to final responses without one, to supply the server timestamp; set `auto_date=false` when an upstream owns that field. |
| Cookies | mttp keeps no cookies unless given `cookies=CookieJar`; storing session state is an application choice. Core exposes parsed `Set-Cookie` values but has no automatic jar in its Client. |
| Decoding and statuses | Standard mttp decoders accept 2xx and keep status/decoding failures as values, so callers can inspect the HTTP response without treating it as a network failure. Use `any_status()` when other statuses are part of the API. |

For native/wasm, core automatically decompresses gzip; mttp also supports
deflate, br and zstd. On js, both clients leave decompression to the host.

## Lower-level core features to keep or adapt

Core's `ClientConnection::end_request(on_informational_response=...)`
exposes intermediate 1xx responses. mttp's high-level Client exposes the
final response, not that callback. Keep the low-level core connection if
your application needs to observe each informational response.

Core's `ClientConnection::trailer` and `ServerConnection::trailer` expose
received trailers, and `enter_passthrough_mode` exposes a raw tunnel after
CONNECT or an upgrade. mttp's ordinary Response and Handler API does not
expose those connection methods. Keep core for generic tunnel/trailer
workflows or write an adapter; for WebSockets, use mttp's dedicated
`gaato/mttp/ws` package instead of treating a normal body as a tunnel.

Core connection types implement its `BinaryReader`/`BinaryWriter` traits
and offer `.text` views. mttp bodies use the smaller `BodyStream` pull
interface. Adapt existing producers and consumers explicitly; moving a
connection into a returned body changes who closes it.

## Coming from `moonbitlang/async/http`

The registry release checked for this guide is `moonbitlang/async` **0.22.9**.
Its `src/http` is a separate implementation using that module's runtime,
I/O and socket packages, not a re-export of `moonbitlang/core/async/http`.
Do not assume that changing an import alone migrates a low-level program.

In 0.22.9, top-level `get` returns `(Response, &io.Data)`, whose body has
`text()`, `json()` and `binary()` methods; it is not core's `MessageBody`.
There is no `post_json` helper in this release: `post` takes `&io.Data`, and
`Json` implements `Data`. Replace that with mttp's `post(...).body_json(...)`.
The package calls its response header `Response` and its request header
`Request`; its URL error is `URIParseError` (core spells it `UriParseError`).
Its `Client(origin)` is a live connection: call `request`, write the body,
call `end_request`, and consume or skip the response before another
request. In the pinned core these operations belong to `ClientConnection`;
core's `Client(headers=...)` is the higher-level wrapper. Moving to mttp's
Client means replacing that manual sequence with `send` and a response plan,
not translating each old method name.

The 0.22.9 server callback is `(Request, &Reader, ServerConnection) -> Unit`;
core's callback is `(RequestHeader, ServerConnection) -> Unit`. Move reads
from the separate reader to `request.body`, writes to a returned Response,
and shutdown to `server.serve` as above. Replace old `io.Reader`/`io.Writer`
adapters with `BodyStream` adapters as needed. If the app retains task
groups, move its runtime imports to `moonbitlang/core/async` with the
experimental opt-ins required by 0.10.21. Remove the old module dependency
only after no other code uses it; its types and mttp's runtime types do not
interchange.

## Checked local run

From the repository root:

```sh
moon run examples/migrate
moon run scripts/readme_check.mbtx -- --self-test
```

The runner starts both implementations in-process on free loopback ports
and calls each with both clients. It makes no external requests; loopback
sockets are necessary because core has no interchangeable in-process
backend. It checks results, status handling and the 64 KiB limit. It does
not measure pool reuse, trigger deadlines, test a live TLS peer or time an
active shutdown drain.

<!-- output: examples/migrate -->
```text
core server
GET: text and JSON agree
POST: JSON echo agrees
timeout: successful calls agree
reuse: two calls agree
errors: 404 handled on both sides
stream: 8 bytes on both sides
bounds: 65537-byte request refused with 413
mttp server
GET: text and JSON agree
POST: JSON echo agrees
timeout: successful calls agree
reuse: two calls agree
errors: 404 handled on both sides
stream: 8 bytes on both sides
bounds: 65537-byte request refused with 413
```

The documentation check compares every marked source block byte for byte
with its compiled file and the output with this run. The guide must contain
source and output checks and every MoonBit block must have a source marker;
it needs no duplicate excerpt or badge. The self-test alters source/output
lines, removes comments (including one source comment among many) and breaks
a link, and verifies that each alteration fails.

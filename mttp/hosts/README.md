# gaato/mttp/hosts

Host shims: JavaScript files, not a MoonBit package, that connect a
compiled MoonBit `fetch` export to Workers, Deno, Bun, Node, Fastly, Vercel
and Lambda.

They ship inside the published module: after `moon add gaato/mttp`
they are at `.mooncakes/gaato/mttp/hosts/adapters.mjs` and
`.mooncakes/gaato/mttp/hosts/lambda.mjs`; import them from there or
copy them next to your entry. They have no dependencies.

## The MoonBit side

The app's js package exports a `fetch(request, background)` function that
calls a `gaato/mttp/fetch` adapter, and for Workers a
`fetch_with_env(request, background, env)` that associates the bindings
first:

```moonbit
///|
let adapter : (@fetch.JsRequest, @fetch.JsBackground) -> @fetch.JsPromise = @fetch.fetch_handler(request => {
    @mttp.Response::new(200, body=request.body)
  },
)

///|
pub fn fetch(
  request : @fetch.JsRequest,
  background : @fetch.JsBackground,
) -> @fetch.JsPromise {
  adapter(request, background)
}

///|
pub fn fetch_with_env(
  request : @fetch.JsRequest,
  background : @fetch.JsBackground,
  env : @fetch.JsEnv,
) -> @fetch.JsPromise {
  adapter(@fetch.with_env(request, env), background)
}
```

Its `moon.pkg` builds an ES module that exports them:

```text
supported_targets = "js"

options(
  link: { "js": { "exports": [ "fetch", "fetch_with_env" ], "format": "esm" } },
)
```

In the handler, read a Workers string binding with
`@fetch.env_string(env, "NAME")`. The
[fetch package](https://github.com/gaato/mttp/tree/main/mttp/src/fetch)
describes the adapter, and
[examples/fetch](https://github.com/gaato/mttp/tree/main/examples/fetch) is a
complete setup.

## The JavaScript side

`./app.js` below stands for the module `moon build --target js` writes.

```js
// Cloudflare Workers module entry: give workers() a loader, not the function.
import { workers } from './adapters.mjs';
export default workers(() => import('./app.js'));
```

```js
// Fastly, Vercel, Deno, Bun and Node: import the app statically.
import { fetch } from './app.js';
import { fastly, vercel, deno, bun, node } from './adapters.mjs';

// Fastly event entry:
addEventListener('fetch', fastly(fetch));

// Vercel entry: import { waitUntil } from '@vercel/functions', then export:
// export default vercel(fetch, waitUntil);

// Deno: const app = deno(fetch); Deno.serve(app.fetch);
// Bun: const app = bun(fetch); Bun.serve({fetch: app.fetch, websocket: app.websocket});
// Node: const app = node(fetch); pass app.fetch a Web Request in your HTTP bridge.
```

Workers is the one host that imports the app lazily. Evaluating a compiled
MoonBit module draws its hash seed from `crypto.getRandomValues`
(moonbitlang/core's `builtin/hasher.mbt`), and Workers refuses to generate
random values in global scope: a static import fails at startup with
"Disallowed operation called within global scope". `workers(load)` calls
`load` inside the first request, shares that one import between all
requests, and passes each request to the module's `fetch_with_env`; Workers
accepts `waitUntil` at any point while the request runs. If the import fails,
every request rejects with an Error that names the failure and keeps it as
`cause`; the import is not retried, because a module that threw while
evaluating throws again.
[examples/fetch/workers](https://github.com/gaato/mttp/tree/main/examples/fetch/workers)
is a complete Workers app, which the repository's gates run on workerd.
The check prints `KNOWN` with [workerd #7634](https://github.com/cloudflare/workerd/issues/7634)
only for the matching connection reset while reading an expected 200 response to a partly read or unread upload; successful early responses print `PASS`, while full-body reads, other errors and background completion remain strict.
The example pins workerd with an npm override because Wrangler's own dependency can lag behind the runtime selected for this check.

The other hosts keep the static import. Fastly must call `waitUntil` and
`respondWith` synchronously while it dispatches the event, so the app cannot
be imported later. Fastly allows random values at startup, but its
JavaScript SDK initialises the module while building (Wizer), so the hash
seed is fixed per build. Vercel's Node runtime, Deno, Bun, Node and Lambda allow random values
at startup, and a lazy import would only delay each process's first request
and its background registration.

The process hosts (Deno, Bun, Node) own their shutdown. `deno`, `bun` and
`node` return `{fetch, whenIdle, shutdown}`; stop in this order:

```js
const app = deno(fetch);
const server = Deno.serve(app.fetch);
Deno.addSignalListener('SIGINT', async () => {
  app.shutdown();          // end streams marked close-on-shutdown
  await server.shutdown(); // the host stops accepting and finishes responses
  await app.whenIdle();    // background work registered by handlers
  Deno.exit(0);
});
```

On Bun the middle step is `await server.stop()`; on Node, close your HTTP
server. `shutdown()` ends the body of every in-flight response whose
`@mttp.Response` set `@mttp.close_on_shutdown`, such as every SSE response
from gaato/mttp_core's `endpoint.sse_out` or `sse_body_out`, also one that has no
event yet: the stream ends cleanly after a whole event, its MoonBit body is closed once, and clients reconnect with
`Last-Event-ID`. Without it, the host's shutdown waits for such a stream
forever. Other responses are left to finish. The fetch adapter marks those
responses with a function under `Symbol.for("gaato.mttp.closeOnShutdown")`;
a bridge of your own can call it with an AbortSignal that aborts at shutdown.

A client that disconnects while a body streams ends it quietly: the adapter
closes its source once and closes the stream instead of failing it, so Deno,
Bun and Node log nothing. A disconnect before the response head still rejects
the response Promise, which Deno logs as `AbortError`. A host that aborts
`request.signal` after a successful response (Deno's legacy behavior) cancels
nothing: the adapter drops its listeners once the body ends.

Lambda Function URLs use `lambda(fetch)` from `lambda.mjs`. It translates the
v2 event's raw path/query, base64 body, cookies and domain into a Web Request.
Missing or null event bodies are passed as `undefined`, so the model sees
`Body::Empty`. A present empty string remains a body stream.
Responses preserve separate cookies and encode bytes as base64. It awaits all
registered background work before returning, including failure paths. Input
defaults to 1 MiB and buffered output to 4 MiB, leaving room for the base64
envelope under Lambda's response-size ceiling; large response headers also
consume that platform limit. This adapter does not provide response streaming.

The scheduling contracts come from
[Workers context](https://developers.cloudflare.com/workers/runtime-apis/context/),
[Fastly FetchEvent](https://www.fastly.com/documentation/reference/compute/sdks/javascript/js-compute/globals/interface.FetchEvent/),
[Vercel waitUntil](https://vercel.com/docs/functions/functions-api-reference/vercel-functions-package),
and [Lambda Function URLs](https://docs.aws.amazon.com/lambda/latest/dg/urls-invocation.html).
The process tracker retains pending work and exposes a shutdown join; it does
not override the host's execution time limits or keep an otherwise empty event
loop alive merely by retaining a Promise. It keeps no state per response:
the listener a marked response adds to its shutdown signal goes away with the
body.

## WebSockets

`gaato/mttp/ws.connect` uses the host's message API on JS. `ws.upgrade` keeps
the portable origin, version, key and subprotocol validation; `fetch_handler`
turns its hand-over into the host's special upgrade response. No application
code constructs a Web Response with status 101.

| Host | Client | Server through fetch_handler | Client custom headers / Origin |
|---|---|---|---|
| Node 22+ with global WebSocket | Yes | 501 (a fetch bridge has no upgrade API) | Refused |
| Deno | Yes | Deno.upgradeWebSocket | Refused |
| Bun | Yes | server.upgrade; pass both app.fetch and app.websocket to Bun.serve | Yes, constructor options |
| Browsers | Yes | Unavailable | Refused; the browser owns Origin/cookies |
| Cloudflare Workers | fetch with Upgrade, then accept the returned WebSocket | WebSocketPair and the special Response | Yes, fetch headers |
| Fastly / Vercel / Lambda | Only if a compatible global WebSocket exists | Unavailable in these fetch adapters (501) | Refused |

Text and binary messages, negotiated subprotocols and peer Close code/reason
use the same Session API as native. Host error events become Transport(Network)
and close events become Closed(CloseFrame). A custom Backend and extensions
are refused by JS connect; redirects are disabled. Workers can use `headers`
and `origin`; Bun uses its extended WebSocket constructor. Other hosts refuse
these options instead of silently dropping them.

`ws.connect(..., compression=...)` and `ws.upgrade(..., compression=...)`
have **no effect on JS**. The host owns negotiation, inflation and the wire
window; mttp neither adds its native extension nor compresses a second time.

| Host | Compression behavior through these adapters |
|---|---|
| Node global WebSocket | Undici automatically offers permessage-deflate and handles negotiated receive compression; there is no server upgrade in this adapter. |
| Deno | The built-in WebSocket client and Deno.upgradeWebSocket currently do not negotiate compression; mttp adds no extension header. |
| Bun | The client uses Bun's default compression offer. The server adapter supplies no perMessageDeflate setting and sends without the compress argument; application Bun.serve configuration remains host-owned. |
| Browsers | The user agent chooses its compression offer and performs compression/decompression; the standard constructor has no compression option. |
| Cloudflare Workers | Runtime compression support is enabled by the web_socket_compression compatibility flag (default since 2023-08-15). mttp's fetch-based client supplies no extension header; its WebSocketPair server supplies no compression response header. The mttp option does not enable either. |
| Fastly / Vercel / Lambda | Follow the supplied global WebSocket implementation on clients; no server upgrade in these adapters. |

Sources: [Undici handshake](https://github.com/nodejs/undici/blob/main/lib/web/websocket/connection.js),
[Deno client implementation](https://github.com/denoland/deno/blob/main/ext/websocket/lib.rs),
[Deno server behavior](https://docs.deno.com/examples/websocket_context/),
[Bun compression](https://bun.sh/docs/runtime/http/websockets), and
[Workers compatibility flag](https://developers.cloudflare.com/workers/configuration/compatibility-flags/#websocket-compression).
Host behavior can change with host versions. mttp's queue bounds below apply
to the host's already decompressed messages, after host allocation.

JS hosts cannot pause incoming messages. Each session therefore retains at
most `WsLimits.max_message_bytes` **total queued UTF-8/binary bytes** (also
the per-message and outbound-message ceiling, default 16 MiB), and at most
`max_empty_frames` **queued messages of any size** (default 1024). Crossing
either ceiling drops the queue and makes failure sticky: TooLarge with Close
1009 for bytes, Closed(PolicyViolation) with Close 1008 for count. Web-standard
client close() only permits 1000 or 3000–4999, so those clients send application
4009/4008 when the host rejects 1009/1008. Local errors retain the portable
meaning. Other rejected protocol Close codes likewise use `code + 3000`;
the host API cannot send a status it forbids. The host has already allocated the incoming message: these ceilings
bound retained application state, not the host's receive allocation.

Senders serialize in arrival order. `send_timeout_ms` (30 s) includes their
queue wait and bufferedAmount drain; cancellation or deadline aborts the session.
Close waits at most `close_timeout_ms` (5 s). Where a host cannot terminate a
socket, abort drops application state immediately and calls the host's
`close()` without a code or reason, rather than advertising a normal 1000
closure. The peer sees an empty Close (1005, no status); the local session
still reports Abnormal (1006). This applies to Workers, Deno, Bun (including
its server bridge) and Web-standard clients. A host with `terminate()` also
receives that request and may drop the connection before a Close is delivered.
JS exposes neither frames nor Ping/Pong: `max_frame_bytes`, `ping_interval_ms`
and `pong_timeout_ms` cannot be enforced here; the host owns framing/control
validation and automatic replies. Deno's automatic idle timeout is disabled.

The workerd gate checks text/binary echo, subprotocol and Close reason on real
Workers, including three concurrent server sessions and a Workers fetch-upgrade
client with custom headers against the native echo server. Socket I/O runs
through a request-scoped pump that also registers completion callbacks there:
the shared MoonBit scheduler can resume a coroutine from another request's
event, and Workers drops Promise reactions owned by an ended request. The gate
repeats the sessions and client request for 20 rounds in one isolate to cover
that lifetime boundary. `scripts/gates.sh interop websocket` checks JS mttp clients under the
Node/Deno/Bun images pinned in `interop/images.tsv` against the native echo
server, then Deno and Bun fetch servers. `websocket/local` explicitly uses
installed runtimes and prints their versions for environments without containers.
The Deno and Bun checks also exercise shutdown(), which sends GoingAway,
waits at most close_timeout_ms, then cancels and joins the handler even when
it is waiting outside recv. whenIdle() includes that cancellation cleanup.
Startup is supervised too: a CONNECTING socket closes within the close bound,
and a Bun upgrade still waiting for its socket is abandoned without waiting
for send_timeout_ms. Any late socket is closed without starting the handler.
Shutdown listeners are removed when their owner ends, including startup expiry.
Deno upgrade responses append application header pairs without replacing the
host's Connection, Upgrade or Sec-WebSocket handshake fields; Set-Cookie stays
separate. Bun clients use a Headers object in the constructor's options
overload to preserve repeated list fields in order, as supported by
[Bun's WebSocket header type](https://github.com/oven-sh/bun/blob/main/packages/bun-types/bun.d.ts).

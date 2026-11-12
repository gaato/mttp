# gaato/mttp_async/fetch

A handler as a JavaScript `fetch` export, for Web Request/Response hosts.

`fetch_handler(handler)` adapts a `@mttp_core.Handler` to the hosts' `fetch`
convention. The public externs do not expose async-runtime types.

```mbt check
///|
#cfg(target="js")
test "a fetch adapter can be assembled without a host runtime call" {
  let adapter = @fetch.fetch_handler(_ => @mttp_core.Response::new(204))
  ignore(adapter)
}
```

## Exporting the handler

JavaScript sees only exported functions: export a `pub fn` from the app's js
package that calls the adapter (exporting a top-level `let` creates no
JavaScript export). Build the adapter once, at the top level:

```mbt nocheck
///|
let adapter : (@fetch.JsRequest, @fetch.JsBackground) -> @fetch.JsPromise = @fetch.fetch_handler(request => {
    @mttp_core.Response::new(200, body=request.body)
  },
)

///|
/// The entry for Deno, Bun, Node, Fastly, Vercel and Lambda.
pub fn fetch(
  request : @fetch.JsRequest,
  background : @fetch.JsBackground,
) -> @fetch.JsPromise {
  adapter(request, background)
}

///|
/// The entry for Cloudflare Workers: makes the bindings available to the
/// handler through the `env` attribute.
pub fn fetch_with_env(
  request : @fetch.JsRequest,
  background : @fetch.JsBackground,
  env : @fetch.JsEnv,
) -> @fetch.JsPromise {
  adapter(@fetch.with_env(request, env), background)
}
```

The package's `moon.pkg` builds it for js as an ES module that exports those
functions:

```text
import {
  "gaato/mttp_core",
  "gaato/mttp_async/fetch",
}

supported_targets = "js"

options(
  link: { "js": { "exports": [ "fetch", "fetch_with_env" ], "format": "esm" } },
)
```

`moon build --target js` then writes the module under `_build/js/`, and a
host shim from [`hosts/`](https://github.com/gaato/mttp/tree/main/mttp_async/hosts)
connects it to the host. [examples/fetch](https://github.com/gaato/mttp/tree/main/examples/fetch)
is this setup in full, with a Cloudflare Workers app that the repository's
gates run on workerd.

## Background work and aborts

The host calls `fetch(request, background)`. `background` receives exactly one
Promise synchronously, before the adapter returns its response Promise. Work
registered through `@mttp_core.background` before the handler returns is included
in that aggregate; it can outlive the response. Every registered task settles
before the aggregate resolves or rejects. Late scheduling is ignored. Request
abort before the response head cancels handling and rejects the response
Promise. After the head, it ends the response body quietly: the source is
closed once and the stream closes instead of failing, because the client is
gone and an error would only be logged by the host. Already scheduled
background work has an independent lifetime owned by the host's
waitUntil/shutdown policy.

## Bounds and failures

The request ceiling defaults to 1 MiB. Declared overflow is rejected before
the handler (413); observed overflow remains a failure even if the handler
catches it. Invalid request framing/length is 400. Negative adapter limits or
invalid response headers/status are 500. A failure after the host response has
been returned errors its stream, because its status can no longer be changed.
A handler that catches a request-body failure and answers anyway still gets
413 or 400.

Input/output chunks delivered to MoonBit or the host are at most 64 KiB. Input
retains at most one host-provided chunk within the configured ceiling; an
already allocated host chunk cannot be prevented by this adapter. An output
retains one application-provided chunk. Empty input chunks have a 1024-read
budget. EOF, failure, cancellation and HEAD/no-body responses release owned
streams. Input remains open for lazy response readers (including echo) until
output completes. Web Headers may combine ordinary duplicate fields; response
Set-Cookie entries remain separate on hosts with the standard getSetCookie
API.

The host request body is locked to a reader only when the handler first reads
it, and it is never cancelled: at EOF, when the handler closes it, or before
the host receives a reply that does not stream, the lock is released and the
host keeps what is left unread.

## Shutdown

Once a response body has ended, the adapter no longer listens to the request
signal, so a host that aborts it after a successful response (Deno's legacy
behavior) cancels nothing and logs nothing. A streamed response whose
attributes set `@mttp_core.close_on_shutdown` (every `endpoint.sse_out` and
`sse_body_out` response) carries a function under
`Symbol.for("gaato.mttp.closeOnShutdown")`. The process host shims call it
with their shutdown signal; when that aborts, the body ends cleanly between
two reads of its source, so an SSE stream ends after a whole event, and the
source is closed once. The adapter returns the Response, and with it that
function, only after the first output chunk; an endpoint event stream gives
an SSE comment as that chunk, so its Response exists before the first event
and a shutdown also ends a stream that has none yet.

## Bindings on Workers

Use `with_env(request, value)` in the Workers entry before calling the adapter;
the opaque environment is then available through the `env` attribute. Other
hosts leave it absent. The association uses a WeakMap and does not modify the
Request object. `env_string(env, "NAME")` reads a string binding, such as a
`vars` entry or a secret, and is `None` when the binding is absent or not a
string (a JSON var, a KV namespace); it never raises.

See the [host shims](https://github.com/gaato/mttp/tree/main/mttp_async/hosts)
for Workers, Fastly, Vercel, Node, Deno, Bun and Lambda Function URLs. Lambda
passes `undefined` for absent or null event bodies, preserving `Body::Empty`;
a present empty string remains a body stream. The behavior
uses the [Fetch](https://fetch.spec.whatwg.org/) and
[Streams](https://streams.spec.whatwg.org/) APIs.

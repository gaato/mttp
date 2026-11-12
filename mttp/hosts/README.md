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
    @mttp_core.Response::new(200, body=request.body)
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
// Bun: const app = bun(fetch); Bun.serve({fetch: app.fetch});
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
`@mttp_core.Response` set `@mttp_core.close_on_shutdown`, such as every SSE response
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

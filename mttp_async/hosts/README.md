# Fetch host entries

These small adapters accept your compiled MoonBit application functions.
They ship inside the published module: after `moon add gaato/mttp_async`
they are at `.mooncakes/gaato/mttp_async/hosts/adapters.mjs` and
`.mooncakes/gaato/mttp_async/hosts/lambda.mjs`; import them from there or
copy them next to your entry. They have no dependencies.
They do not load a generated module asynchronously: that would postpone the
first `waitUntil` beyond Fastly's synchronous event dispatch.

Export a `fetch(req, background)` function which calls your stored
`fetch_handler(handler)` closure. For Workers also export
`fetch_with_env(req, background, env)` which first calls
`@fetch.with_env(req, env)` and then invokes that closure.

```js
import { fetch, fetch_with_env } from './app.js';
import { workers, fastly, vercel, deno, bun, node } from './adapters.mjs';

// Cloudflare Workers module entry:
export default workers(fetch_with_env);

// Fastly event entry (use in its own entry module):
addEventListener('fetch', fastly(fetch));

// Vercel entry: import { waitUntil } from '@vercel/functions', then export:
// export default vercel(fetch, waitUntil);

// Deno: const app = deno(fetch); Deno.serve(app.fetch);
// Bun: const app = bun(fetch); Bun.serve({fetch: app.fetch});
// Node: const app = node(fetch); pass app.fetch a Web Request in your HTTP bridge.
```

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
from gaato/mttp's `endpoint.sse_out`: the stream ends cleanly after a whole
event, its MoonBit body is closed once, and clients reconnect with
`Last-Event-ID`. Without it, the host's shutdown waits for such a stream
forever. Other responses are left to finish. The fetch adapter marks those
responses with a function under `Symbol.for("gaato.mttp.closeOnShutdown")`;
a bridge of your own can call it with an AbortSignal that aborts at shutdown.

A host that aborts `request.signal` after a successful response (Deno's legacy
behavior) cancels nothing: the adapter drops its listeners once the body ends.

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

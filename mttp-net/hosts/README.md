# Fetch host entries

These small adapters accept your compiled MoonBit application functions.
They do not load a generated module asynchronously: that would postpone the
first `waitUntil` beyond Fastly's synchronous event dispatch.

Export a `fetch(req, background)` function which calls your stored
`fetch_handler(handler)` closure. For Workers also export
`fetch_with_env(req, background, env)` which first calls
`@fetch.with_env(req, env)` and then invokes that closure.

```js
import { fetch, fetch_with_env } from './app.js';
import { workers, fastly, vercel, deno, bun } from './adapters.mjs';

// Cloudflare Workers module entry:
export default workers(fetch_with_env);

// Fastly event entry (use in its own entry module):
addEventListener('fetch', fastly(fetch));

// Vercel entry: import { waitUntil } from '@vercel/functions', then export:
// export default vercel(fetch, waitUntil);

// Deno: const app = deno(fetch); Deno.serve(app.fetch);
// Bun: const app = bun(fetch); Bun.serve({fetch: app.fetch});
// Await app.whenIdle() during orderly shutdown of either process host.
```

Lambda Function URLs use `lambda(fetch)` from `lambda.mjs`. It translates the
v2 event's raw path/query, base64 body, cookies and domain into a Web Request;
responses preserve separate cookies and encode bytes as base64. It awaits all
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
loop alive merely by retaining a Promise.

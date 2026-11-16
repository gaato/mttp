// Deno/Bun server checks; the interop runner supplies the digest-pinned host.
// Uses the same compiled fetch entry and echo handler as the workerd check.
import {fetch_with_env} from '../../../_build/js/debug/build/gaato/mttp-fetch-example/workers/workers.js';
import {deno, bun} from '../../../mttp/hosts/adapters.mjs';

const fetch = (request, background) => fetch_with_env(request, background, {});
const handler = app => request => {
  if (new URL(request.url).pathname === '/shutdown') {
    app.shutdown();
    return app.whenIdle().then(() => new Response('stopping'));
  }
  return app.fetch(request);
};
if (globalThis.Deno) {
  const app = deno(fetch);
  Deno.serve({hostname: '127.0.0.1', port: 39508}, handler(app));
} else {
  const app = bun(fetch);
  Bun.serve({hostname: '127.0.0.1', port: 39509, fetch(request, server) {
    if (new URL(request.url).pathname === '/shutdown') { app.shutdown(); return app.whenIdle().then(() => new Response('stopping')); }
    return app.fetch(request, server);
  }, websocket: app.websocket});
}

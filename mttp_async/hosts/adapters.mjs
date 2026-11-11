// Each adapter receives the application's compiled MoonBit entry function.
// Keep this call synchronous so Fastly can register waitUntil during dispatch.
export function workers(fetchWithEnv) {
  return {
    fetch(request, env, context) {
      return fetchWithEnv(request, promise => context.waitUntil(promise), env);
    },
  };
}

export function fastly(fetch) {
  return event => {
    const response = fetch(event.request, promise => event.waitUntil(promise));
    event.respondWith(response);
  };
}

export function vercel(fetch, waitUntil) {
  return request => fetch(request, promise => waitUntil(promise));
}

// The fetch adapter puts this function on a Response whose body should end at
// shutdown (gaato/mttp's close_on_shutdown, set on every SSE response). Called
// with an AbortSignal, it ends that body cleanly once the signal aborts; its
// listener goes away with the body.
const closeOnShutdown = Symbol.for('gaato.mttp.closeOnShutdown');

// Process hosts own shutdown: call shutdown(), stop the host's server, then
// await whenIdle(). Merely retaining a Promise does not keep a Node-compatible
// event loop alive.
export function tracked(fetch, onError = console.error) {
  const pending = new Set();
  const stopping = new AbortController();
  return {
    fetch(request) {
      return fetch(request, promise => {
        const task = promise.catch(onError).finally(() => pending.delete(task));
        pending.add(task);
      }).then(response => {
        response[closeOnShutdown]?.(stopping.signal);
        return response;
      });
    },
    async whenIdle() {
      while (pending.size) await Promise.all([...pending]);
    },
    shutdown() {
      stopping.abort();
    },
  };
}

export const deno = tracked;
export const bun = tracked;
export const node = tracked;

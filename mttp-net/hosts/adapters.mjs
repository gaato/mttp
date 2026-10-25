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

// Process hosts own shutdown: whenIdle must be awaited before stopping them.
// Merely retaining a Promise does not keep a Node-compatible event loop alive.
export function tracked(fetch, onError = console.error) {
  const pending = new Set();
  return {
    fetch(request) {
      return fetch(request, promise => {
        const task = promise.catch(onError).finally(() => pending.delete(task));
        pending.add(task);
      });
    },
    async whenIdle() {
      while (pending.size) await Promise.all([...pending]);
    },
  };
}

export const deno = tracked;
export const bun = tracked;

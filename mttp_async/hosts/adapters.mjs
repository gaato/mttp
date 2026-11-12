// Workers forbids generating random values in global scope, and evaluating a
// compiled MoonBit module draws its hash seed from crypto.getRandomValues
// (moonbitlang/core's builtin/hasher.mbt). So this adapter takes a loader,
// `() => import('./app.js')`, and imports the application inside the first
// request; the module must export `fetch_with_env`. Every request shares that
// one import. If it fails, each request rejects with an Error naming the
// failure (the original is its `cause`); the module is not imported again,
// since an ES module that threw while evaluating throws the same error again.
export function workers(load) {
  if (typeof load !== 'function') {
    throw new TypeError("workers() takes a loader such as () => import('./app.js')");
  }
  let entry;
  const loaded = () => entry ??= Promise.resolve().then(load).then(app => {
    if (typeof app?.fetch_with_env !== 'function') {
      throw new TypeError('workers(): the loaded module exports no fetch_with_env function');
    }
    return app.fetch_with_env;
  }, error => {
    throw new Error(`workers(): importing the application failed: ${error}`, {cause: error});
  });
  return {
    fetch(request, env, context) {
      return loaded().then(fetchWithEnv =>
        fetchWithEnv(request, promise => context.waitUntil(promise), env));
    },
  };
}

// The adapters below receive the application's compiled MoonBit entry
// function, imported statically. Fastly needs this: waitUntil and respondWith
// must be called synchronously during dispatch.
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
// shutdown (gaato/mttp_core's close_on_shutdown, set on every SSE response). Called
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

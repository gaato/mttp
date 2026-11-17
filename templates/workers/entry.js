// Import inside the first request: MoonBit initializes its hash seed using
// randomness, which Workers forbids during global module evaluation.
let entry;
export default {
  fetch(request, env, context) {
    entry ??= import('./_build/js/release/build/worker.js');
    return entry.then(app =>
      app.fetch_with_env(request, promise => context.waitUntil(promise), env));
  },
};

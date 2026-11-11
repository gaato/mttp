# Fetch example

Build the JavaScript module with real ESM function exports:

```sh
moon build --target js examples/fetch
```

The artifact at `_build/js/debug/build/gaato/mttp-fetch-example/mttp-fetch-example.js`
exports `fetch` and `fetch_with_env`. Both stream an echo
through the 1 MiB request ceiling and synchronously register background work.
Pass the exported functions to the shims in `mttp_async/hosts` for the selected host.

The fetch package's Node tests import the built artifact and check the actual
exports and Web Request roundtrip. Build this module before running those
tests directly; the full gate builds the examples automatically.

## Cloudflare Workers

`workers/` is a Workers app: a Map built at module level, a JSON reply with a
`vars` binding read by `@fetch.env_string`, a note stored by background
work that `waitUntil` keeps alive, and replies that read the request body
whole, in part or not at all, or discard it unread, most followed by
background work. `entry.js` hands the shim a loader,
`workers(() => import(...))`, because evaluating the compiled module draws a
random hash seed, which Workers refuses in global scope. Run it on workerd
with the wrangler that `package-lock.json` pins:

```sh
scripts/gates.sh workerd
```

That builds the module, runs `npm ci` in `workers/` and then `check.mjs`,
which starts `wrangler dev`, checks the replies and fails on any error or
warning wrangler or workerd logs. The requests that leave the body unread are
repeated 20 times, some with the body sent a moment after the head, because
the failure they guard against appeared in some runs only. `scripts/gates.sh full` and CI run it too.
For a deployment, run `npx wrangler deploy` in `workers/` after the build.

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

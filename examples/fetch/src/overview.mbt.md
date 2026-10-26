# Fetch entry example

A bounded streaming echo showing actual ESM function exports for the
[host adapters](https://github.com/gaato/mttp/tree/main/mttp-net/hosts).
This example is not deployed by the repository's tests.

## Install

Build in the repository workspace:

```sh
moon build examples/fetch/src --target js
```

The generated module exports `fetch` and `fetch_with_env`. Pass these functions
to the relevant host adapter. The runtime gate builds this module and imports
its output to verify that these exports actually exist and serve a request.
It also exports `get_text(url)`, a small Promise-based browser client that owns
and closes its backend and response. `scripts/browser_gate.mbtx` checks both
directions in headless Chromium against a temporary loopback HTTP server.

## License

Apache-2.0.

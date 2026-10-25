# HTTP conformance corpora

This unpublished module checks `gaato/mttp` through public APIs on all four
targets. It retains the HTTP-only suites from mbt-sdk commit `43f92f0`:

- URL parsing against 226 applicable WHATWG URL vectors, with the existing
  explicit RFC 3986 exclusions and skip counts retained.
- Form/query parsing and CookieJar behavior against WPT and http-state data.
- SSE results, truncation, end-of-stream behavior and overflow under every
  short-input split, hostile UTF-8/CRLF splits and seeded mutations.

The SSE size-limit classification is `TransportError(kind=TooLarge)`, matching
the new transport error vocabulary; event results and mutation counts remain
unchanged. The tests use no runtime and no wall clock. Cookie time comes from
the explicit FakeClock. JSON-RPC corpora remain in mbt-sdk.

See [NOTICE](NOTICE) for upstream revisions and licenses. Embedded vectors are
regenerated with [gen_vectors.mbtx](../scripts/gen_vectors.mbtx); its header
documents the required local source files. The regular gates include this
module and enforce equal per-package counts on native, wasm, wasm-gc and JS.

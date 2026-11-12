# HTTP conformance corpora

This unpublished module checks `gaato/mttp_core` through public
APIs on all four targets. It retains the HTTP-only suites from mbt-sdk
commit `43f92f0`:

- URL parsing against 245 applicable WHATWG URL vectors, including all 19
  previously excluded IPv6/IPv4-tail rows. IPv6 serialization uses RFC 5952
  hex throughout. The remaining RFC 3986 exclusions have pinned skip counts.
- Form/query parsing and CookieJar behavior against WPT and http-state data.
- SSE results, truncation, end-of-stream behavior and overflow under every
  short-input split, hostile UTF-8/CRLF splits and seeded mutations.

The SSE size-limit classification is `TransportError(kind=TooLarge)`, matching
the new transport error vocabulary; event results and mutation counts remain
unchanged. The tests use no runtime and no wall clock. Cookie time comes from
the explicit FakeClock. JSON-RPC corpora remain in mbt-sdk.

See [NOTICE](NOTICE) for upstream revisions and licenses. Embedded vector
data is retained verbatim from the reference module. The regular gates include
this module and enforce equal per-package counts on native, wasm, wasm-gc and
JS.

The URL suite intentionally excludes backslash handling, special schemes
without `//`, encoded dot segments, apostrophe encoding in queries, empty
hosts, IDNA/percent-encoded hosts, hosts outside RFC reg-name, noncanonical
IPv4 numeric hosts, and empty userinfo/password normalization. It compares
empty HTTP paths as `/`, as RFC 9110 permits. These are the inherited RFC
3986 conventions, not newly accepted parser failures.

The cookie parser corpus keeps three inherited exclusions: cases disabled
upstream, nameless cookies, and an empty last Domain attribute. The latter
two differ between RFC 6265 and the implemented RFC 6265bis-22. Cookie date,
form and SSE vectors have no exclusions.

From the workspace root, run the suites with:

```sh
moon test conformance/src/cookie conformance/src/sse conformance/src/url --target wasm-gc
scripts/gates.sh full
```

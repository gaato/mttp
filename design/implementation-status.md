# Implementation status

The implementation starts from design commit
`eeed2049d84d1412447780cf13eede401454981a`. The local integration branch is
`ccr-eae554e2-r0xapl-u1`. No implementation has been published.

## Sources

- The interrupted Claude session supplied the Driver, its 38 tests, and the
  initial gate scripts and ledgers. Source was recovered from its file viewer.
- Hardened HTTP and SDK code is being moved from local `gaato/mbt-sdk`
  commit `43f92f0`, retaining its tests and changing the module/API boundaries.
- The archived prototype supplies new API shapes only. It is not the source
  for hardened parsers, multipart streaming or retry logic.
- Digest parsing, hash calculation and reference tests come from local
  `gaato/requesto.mbt` commit `be3dfa395b960746bd5b7976e0de3d6eac480baf`.
- `scripts/docs_audit.mbtx` is copied unchanged from `gaato/discord.mbt`.

## Progress

- U1 in progress: scaffold, Driver, clocks, jsonkit, model, SSE parsing,
  multipart and retry decisions are present. This is not a complete U1.
- Feed, initial quickcheck generators and SSE encoding are now present.
- Remaining U1: the complete generator inventory,
  API review and test-gate negative tests. Driver timer callback and cleanup
  budget regressions have been fixed and have dedicated tests.
- U2 in progress: Backend wrappers, ClientRequest, response readers, request
  defaults, fallback timers and BackendStub are present. Shared split, body
  and backend contract checks and deterministic fault wrappers are present;
  backend checks currently cover invalid input and closed-state behavior.
  Runtime-specific deadline and framing contracts remain with U4/U5.
- U3 in progress: the Client now performs opt-in retries, enforces per-attempt
  and total deadlines, pairs admission with release and reports settled
  attempts. Mature retry presets, WindowLimiter and Paginator are ported with
  their tests. API review and the full consumer conformance suite remain.
- U4 in progress: the unavailable h1client scratchpad probe is being rebuilt
  from the accepted design. The runtime-free h1 codec now has bounded head
  accumulation, strict request/response parsing, framing decisions, a bounded
  chunk decoder, and wire writers. Split invariance, premature EOF, framing
  conflicts, limits and pipelined-byte ownership have tests. Runtime socket
  integration is now present in H1Backend; the complete adversarial and
  consumer socket conformance suites remain.
- `mttp-net/backend` now has native/wasm direct HTTP and verified HTTPS,
  bounded response framing, incremental decoding, bounded writes, pooled
  connections, admission and phase/total deadlines. Loopback tests cover
  framing failures, upload lengths, body ownership, stale reuse, cancellation,
  decoding limits and TLS trust. The global idle cap is 256. Mature proxy
  configuration, NO_PROXY and reference tests are ported; bounded CONNECT
  and nested TLS have loopback tests. AsyncBackend now selects the socket
  backend or JS fetch with a shared constructor. JS tests cover bounded
  uploads/reads, manual redirects, timeout/parent cancellation, and actual
  Node fetch against a loopback server. Browser-host conformance remains.
- `mttp-net/runtime` now provides AsyncClock, ClockTimer and SemaphoreGate
  using the mature adapters. Native, wasm and JS tests cover completion,
  timeout, parent cancellation and admission cancellation. The approximate
  legacy VirtualClock has not been copied; deterministic core tests use Driver.
- `mttp-net/codings` ports the mature incremental gzip/deflate/br/zstd chain,
  including retained randomized split, corrupt-stream and decompression-bomb
  tests. Its public decoder enforces one-to-five stages and refuses feed/end
  misuse without overwriting unread bytes. All four targets are gated.
- U6 has the mature CookieJar and a Cookies backend wrapper, including its
  bounds, expiry, domain/path and credential-header tests. FollowRedirects
  ports the mature redirect planner, closes intermediate bodies, records
  final URL/history, and composes with Cookies. Bounded line readers, form
  decoding and paired response readers are present. URI interpolation encodes
  components and omits None query values; curl diagnostics redact sensitive
  headers without consuming streams. The quick facade lazily shares a Client
  and supports explicit close/recreation on native, wasm and JS.
- Remaining U4–U9 work includes socket/browser conformance, the runtime server,
  fetch handler, response compression integration, consumer migrations and
  remaining U1–U3 checks.
- A native/wasm HTTP/1 server now passes 25 tests on each target: bounded heads and
  bodies, keepalive/draining, lazy 100 Continue, response compression,
  disconnect cancellation, graceful shutdown and background work are present.
  Static gates pass; six uncovered shutdown/error race guards are explicitly
  queued for deterministic injection in TEST_COVERAGE.md.
  A loopback test exposed a remaining H1Backend conformance issue: when a
  server rejects a large upload immediately with 413 and closes, the backend
  can report Network during Write before reading the final response. The
  upload/head orchestration must handle early final responses; this remains
  outstanding rather than being counted as server/client conformance success.
- `mttp-net/codings` now also provides bounded gzip/deflate/Brotli encoders,
  quality-weight negotiation and a lazy body wrapper. Each input chunk is
  sync-flushed, and output is at most 64 KiB per pull. Thirty-two coding tests pass
  on all four targets, including mid-stream decoding and ownership on EOF,
  failure and cancellation. Zstd remains decode-only in the codec dependency.
- The separate `mttp-digest` module now wraps Backends with an origin-scoped
  DigestScheme. Mature requesto hash/parser tests are retained, with additional
  contract, replay/close, cross-origin, stale-nonce and challenge-budget tests.
  It imports crypto without adding that dependency to mttp or mttp-net.
- U8 schema codecs are present: typed text/JSON/body codecs, exact int64
  numbers, accumulated pointer-path issues, optional/presence fields,
  object1–object8, bounded recursive codecs, unions and a bounded ECMA pattern
  subset. Shared internal form/text helpers keep schema independent of model
  without duplicating encoders. Schema construction now retains conflicting
  named definitions and duplicate fields for endpoint definition checking.
- U8 endpoint/client/server interpreters and the in-process Router are present.
  Tests cover staged security, repeated input rejection, typed round trips,
  rest captures, response headers/cookies, dynamic status/media types, SSE,
  middleware cancellation and streamed request/response ownership. The shared
  checker covers routing conflicts, invalid captures, body combinations,
  response header conflicts, operation IDs and schema-name conflicts.
- U9 apispec/OpenAPI and endpoint/testkit are present. Explicit generated JSON
  codecs omit absent optional fields and flatten x-* extensions. Projection
  tests cover response merging, typed headers, AND security, local references
  and a documentation endpoint. A typed stub round trip preserves declared
  application errors.
- Endpoint/document verification checkpoint: every core and Digest package
  passes on all four targets with equal test counts. Static gates pass,
  including runtime loopback tests, documentation and resource-bound audits,
  and native coverage (545 tests). The closed coverage ledger records only
  unreachable construction/forward-compatibility guards in the new packages.
  This validates these packages, not the remaining runtime and migration work.

## Port decisions

- Headers retain normalized names, ordering and duplicates, but updates
  return new values. Existing tests now retain those return values.
- Request body acquisition retains the existing `StreamBody` take-once
  mechanism. A taken stream now rejects empty chunks and closes on error,
  cancellation and EOF. The contract requires sticky EOF and nonempty chunks.
- Runtime multipart tests now use plain tests and the deterministic Driver.
  Their fake filters empty source chunks to satisfy the new BodyStream
  contract; explicit empty-chunk rejection is covered in model tests.
- Retry policy and jitter remain the mature implementations. Invalid,
  protocol, limit, closed and unreplayable failures cannot be retried.
- Query appending preserves a fragment at the end, including a question
  mark inside the fragment, as required by the design checklist.
- Full local gates include coverage, matching the CI checks.
- `from_head` selects once and runs the selected reader inside the attempt,
  as specified by the accepted design. Explicit streaming readers run after
  the attempt and close their response even when the callback fails.
- A completed fallback-timer callback wins a simultaneous expiry, retaining
  ownership of its returned stream so it can be consumed and closed.
- Body factories run after admission. A stream without a factory is never
  retried, even if a custom decider requests it. Reader failures release with
  the received response's status and headers.
- WindowLimiter's white-box cleanup tests retain their internal assertions
  but use Driver instead of raw coroutine intrinsics. Their two test-only
  imports are explicitly ledgered rather than exposing private maps.

The latest pinned toolchain is `0.10.17+d971670cd`. Tests must be rerun after
changes; earlier checkpoint counts are not a completion claim.

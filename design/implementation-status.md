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
- `scripts/docs_audit.mbtx` is copied unchanged from `gaato/discord.mbt`.

## Progress

- U1 in progress: scaffold, Driver, clocks, jsonkit, model, SSE parsing,
  multipart and retry decisions are present. This is not a complete U1.
- Feed, initial quickcheck generators and SSE encoding are now present.
- Remaining U1: reusable contract suites, the complete generator inventory,
  API review and test-gate negative tests. Driver timer callback and cleanup
  budget regressions have been fixed and have dedicated tests.
- U2–U9 remain: client and stubs, retry/deadline/rate-limit orchestration,
  runtime and HTTP/1 adapters, socket conformance, client conveniences,
  digest, schema/endpoints, router/server and OpenAPI generation.

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

The latest pinned toolchain is `0.10.17+d971670cd`. Tests must be rerun after
changes; earlier checkpoint counts are not a completion claim.

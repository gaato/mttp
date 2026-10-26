# Typed responses and SDK contracts

This is the implementation follow-up to portable-engine commit `632b514`.
The HTTP engines, connection ports, framing rules and runtime adapters stay
the foundation. The changes below replace the corresponding exception-first
client and endpoint sections in `design.md`.

## Accepted contracts

- Requests and response descriptions distinguish buffered and streaming
  processing in their types. Both use `.response(...).send(client)` and one
  concrete Client executor; applications do not carry executor wrapper types.
- Built-in response readers return `Result` for rejected HTTP responses and
  decoding failures. `ResponseFailure` retains the head and bounded diagnostic
  bytes. Transport failures still raise `TransportError`; cancellation and
  unknown user exceptions retain their identity.
- Endpoint errors are ordinary values, without an `Error` bound. The client
  result is `Result[Result[O, E], ResponseFailure]`; server authentication and
  business handlers return Result. These wrappers never change wire JSON.
- A response mode describes possible streaming, whereas the head-selected
  branch decides actual execution. Metadata selection must not turn a stream
  callback into a retryable buffered operation. `as_both` accepts only buffered
  descriptions; buffered branches may explicitly widen to streaming mode.
- Retry policy is data plus an optional typed decision function. The executor
  enforces the retry count, replay source and remaining budget. A callback that
  has started is never replayed. Vendor presets belong to the relevant SDK.
- An Idempotency-Key header alone does not establish that a service supports
  deduplication. Generic idempotency uses the method or explicit replay_safe.
- A total deadline covers admission, body preparation, attempts, backoff and
  stream consumption. It requires a Timer; invalid configurations fail before
  admission or body acquisition. No consumer starts after expiry.
- Each completed admission has one release invocation. Release must complete
  or roll back safely when cancelled. Synchronous close and compensation run
  during unwind; only necessary asynchronous cleanup is shielded. A deadline
  requests cancellation and may be followed by required cleanup time.
- Expected response failures are values, not failed effects. An operational
  release error propagates when the exchange produced a value, including an
  error-valued response; an existing raised exchange error or cancellation is
  not replaced by a release error. This follows the new value/effect boundary
  rather than trying to infer business success from an opaque result type.
- Attempt observations retain actual HTTP metadata, raised errors and retry
  decisions. SDK business success is not inferred by the transport. Logical
  calls, policy attempts, redirects and stale-connection repair are distinct.
- SDKs expose expected API/decode/validation failures as values and propagate
  TransportError separately. Paginator EOF, cursor advancement and pending
  items retain their existing contracts. sdk-runtime stays as a regression
  reference until consumers migrate; no mttp-sdk module is introduced now.

## Verification before implementation

- Client/Endpoint/Router: 120 existing tests on each of four targets.
- Runtime: 16 existing tests on native, JS and Wasm.
- SDK behaviour: 59 tests on native; coordinator EOF release: one loopback test.
- An external-package type probe passed on all four targets. Streaming-only
  endpoints reject buffered requests, and as_both rejects streaming readers.
- A typed retry model passed on all four targets without throwing error values.
- Native/JS/Wasm runtime probes covered admission expiry, stream cancellation,
  protected async cleanup, preservation of ordinary exceptions and compensating
  release. Unprotected async defer was correctly shown to be cancellable.

These are baseline/prototype results, not validation of the new implementation.

## Implementation and release order

1. Client descriptions, Result readers, typed retry and whole-call deadline.
2. Endpoint/server/router/OpenAPI contracts and lifecycle regression tests.
3. SDK, Discord/Voice, CLI and generator migrations with retained behaviour.
4. Public compile/compile-fail fixtures, all target and runtime gates, real
   transport/browser tests, bounds/coverage/docs and isolated package graphs.
5. Review the concrete candidates; publish mttp before switching and releasing
   dependent SDKs. Related PRs remain drafts until the dependency is published.

Runtime/core upgrades and new protocol features are separate changes. Reviewed
history is preserved with follow-up commits. Dependency synchronization is
serial across the workspaces because their shared caches can be transiently
incomplete when multiple moon processes synchronize them concurrently.

## Progress

- Client, readers, request modes, typed retry, whole-call timer and paginator
  implemented. Vendor retry presets removed from the core. `mttp-net.new_client`
  supplies a backend, clock and timer; quick uses this factory.
- Endpoint modes and nested Result client/server contracts implemented. Router
  ownership and wire representations retained. Client/Endpoint/Router passed
  131 tests on each of four targets, including bounded unknown representations,
  declared stream errors, auth failure values and fluent request composition.
- Runtime passed 20 tests on native, JS and Wasm, including four new whole-call
  cancellation, rollback and exception-identity cases.
- All four-target packages passed their per-package checks and tests, and
  scripts/test_manifest.tsv was regenerated. Two old header-only idempotency
  expectations were aligned with the accepted explicit replay-safety contract.
- OpenAI, Anthropic and GitHub facades and generated decoders migrated. Their
  historical behavior suites passed all 59 tests on native and JS through
  test-only adapters. SDK/decoder fixtures passed 111 tests on all four targets,
  including direct value/transport/callback identity contracts. Retained legacy
  sdk-runtime passed 53 tests on each target.
- The combined workspace, including Discord examples, guides and template,
  passed --deny-warn checks on all four targets. Discord/Voice/guide tests passed
  1,561 native, 1,288 JS and 1,317 Wasm tests. CLI passed 12 native and 12 Wasm
  tests and both release builds; the built native executable's help was checked.
  moon run with the external CLI path chose its old sibling workspace, so that
  invocation is not used as evidence for the current dependency graph.
- Framework effectful handlers use a framework-owned RestError containing the
  normal REST failure value; raw TransportError and unknown exceptions retain
  identity. This adapter stays above the REST SDK rather than becoming another
  shared SDK runtime.
- Attempts expose caller Attributes separately from the pure RequestHead.
  Discord records a per-call bounded excerpt in an explicit private annotation
  for its 429 telemetry. The typed retry decider itself remains pure.
- Exported-interface probes in a separate consumer module passed all targets;
  as_both with a streaming reader and buffered request on a stream-only Endpoint
  are rejected on every target. This is retained as scripts/type_contracts.mbtx.
- SDK, Discord and CLI documentation audits passed, as did Discord clock,
  facade-surface, callback-schema and CDN audits and the SDK bounds ledger.
- Generator unit tests (68), regeneration checks, core manifest/static gates,
  every runtime manifest row and an actual Chromium Fetch run (5 cases) passed.
  Native coverage ran 653 tests: mttp 4,879/4,916 lines (99.2%), mttp-net
  1,360/1,389 (97.9%) and Digest 222/222 (100%). Every uncovered line is
  explained; the physical listener shutdown races remain explicitly unforced.
- Real package archives for the complete mttp/SDK/Discord/Voice/CLI graph
  compiled from an isolated registry without workspace overrides. Live provider
  calls and remote deployments were not run.
- Default consumer workspaces no longer require external sibling directories;
  this addresses the SDK/CLI checkout review findings. Candidate source checks
  use the external integration workspace. Standalone CI still requires mttp's
  referenced versions to be published before the consumer release.
- SDK #61, Discord #59 and CLI #1 were verified to remain drafts. Changes are
  prepared locally; there has been no push, PR mutation or package publication
  during this Result/mode follow-up. Remote CI and reviews still apply to their
  previous heads. Publication remains a separately confirmed operation.

# Integration validation

All commands below run locally. The release helper's publication list remains
empty; none of these checks uploads packages or changes GitHub state.

| Check | Command from the mttp checkout | Evidence |
|---|---|---|
| Core and runtime gate | `scripts/gates.sh full` | Four-target core/Digest/corpus counts, target-specific runtime tests, generated interfaces, docs, bounds and native coverage ledger |
| Gate negative cases | `moon run scripts/gate_selftest.mbtx` | A passing miniature workspace, unexpected zero tests, a failing assertion, extra tests and a missing manifest row |
| Resolver negative cases | `moon run scripts/resolver_gate.mbtx --self-test` | Existing-version collisions and same-version manifest/index dependency drift are refused |
| Packaged core candidates | `moon run scripts/resolver_gate.mbtx` | Real `moon package` ZIPs in an isolated copy of the registry, built by consumers outside any `moon.work` |
| Packaged migration graph | `moon run scripts/resolver_gate.mbtx SDK_ROOT DISCORD_ROOT CLI_ROOT` | The above plus OpenAI, Anthropic, GitHub, codex-protocol, Discord, native Voice and the CLI; targets follow each module's supported surface |
| Actual browser | `moon run scripts/browser_gate.mbtx` | Chromium with a new temporary profile: Unicode streaming, synchronous background registration, pre-abort, cancellation cleanup, overflow before/after response headers and a real loopback network GET through AsyncBackend |

The resolver requires the regular Moon registry cache/index used by the
workspace and command-line `cp`, `mktemp`, `sha256sum` and `unzip`. Packaging
copies modules outside their source workspaces, so sibling overrides cannot
mask a dependency mismatch. The browser check uses
`chromium` (or `CHROMIUM`), Python's standard-library HTTP server, and a temporary
directory containing only its test artifacts. Both print their evidence paths.

Resolver artifacts default to `/var/tmp`; `MTTP_RESOLVER_TMPDIR` can select a
different disk-backed directory. Native builds can exceed a tmpfs quota, and
staging beneath an ignored checkout directory can make `moon package` omit
files. The gate checks each archive for its module manifest before resolving it.

## Public interface review

The generated interfaces keep runtime implementation types out of the library
surface. The paired-target check explicitly permits H1Backend only on socket
targets, an empty server package on JS, and an empty Fetch package on non-JS
targets. Those empty packages permit portable consumers under the pinned
compiler, whose imports cannot be conditional; they do not implement adapters
on unsupported targets.

The extensible enums listed in design section 5.6 are checked in generated
interfaces, including Body and retry Decision. Unknown body variants fail
closed in readers/writers; unknown retry decisions stop. A stream without a
factory is never automatically retried, even before it has been taken:
`Body.is_replayable()` also covers the existing first-use availability of a
stream and is not the Client's retry predicate.

The six bounded generator primitives are inventoried in
`mttp/src/testing/gen/README.mbt.md`; protocol corpora supply protocol-specific
values. OpenAPI projection rejects schema/security component names outside
the [Components key grammar](https://spec.openapis.org/oas/v3.1.0#components-object),
while ordinary JSON Schema property names remain unrestricted.

## Limits of the evidence

Loopback tests cover 32 incomplete-header connections, repeated header and
chunk-line floods, conflicting framing, oversized bodies, draining and a
trickling body that cannot renew its deadline. These are functional bounds
tests, not a production capacity benchmark. The coverage ledger still names
the six unforced shutdown/accept interleavings rather than treating them as
executed.

A native debug run of just the slow-header and repeated-flood tests (the
already-built test executable, without compiler processes) completed in 0.51 s,
used 0.03 s user / 0.01 s system CPU, and peaked at 17,184 KiB RSS under
`/usr/bin/time -v`. Both test-result records were successful. This is one local
measurement including the test clients, not a portable performance threshold.

Workerd and local Fastly/Vercel/Lambda adapter tests are consumer evidence.
Remote cloud deployment, actual Fastly Compute, Deno and Bun processes and live
provider credentials are not part of the observed results. The unchanged
opt-in legacy badhttp suites are not evidence for the new transport; its
malformed-wire tests use local peers.

All migration manifests reserve new versions. No registry release, public PR,
push or remote deployment is implied by a passing local gate.

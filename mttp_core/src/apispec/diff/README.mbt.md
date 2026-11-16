# OpenAPI compatibility comparison

`gaato/mttp_core/apispec/diff` compares `apispec.OpenApi` values decoded with
`FromJson`. It owns the comparison policy separately from document data:
this follows design §3.5, as `openapi` separately owns projection.

```mbt check
///|
test {
  let before = @apispec.OpenApi::new(@apispec.Info::new("Example", "1"))
  let after = @apispec.OpenApi::new(@apispec.Info::new("Example", "2"))
  let report = @diff.compare(before, after)
  assert_true(report.complete())
  assert_eq(report.breaking(Client).length(), 0)
  let _ : Json = report.to_json()
}
```

`Report.request` and `.response` contain `Change` values, each with an RFC 6901
pointer, a `ChangeKind`, and Client and Server severities. `Change::severity`
selects a view; `Report::breaking` selects its breaking changes. `ToJson`
produces `{ "request": [...], "response": [...] }` with kebab-case kind names,
`path`, `client`, `server`, and the kind's payload. Paths refer to the new
source (old source for removals), except effective inherited settings are
reported at their operation. Referenced schemas use their target pointer.

The Client view assumes strict generated response decoders: adding response
enum values or nullability is breaking; removing a response required guarantee
is breaking. The Server view tolerates new response variants. Request
restrictions break existing callers in both views. Unknown keyword changes,
formats, unresolved references and schema composition changes are warnings;
type replacements are conservatively breaking for clients. This is a
structural comparison, not a JSON Schema implication prover.

Operations, paths, parameters (including inherited overrides and renamed path
variables matched by position), request bodies, media types, response codes,
effective security alternatives and server URLs are compared. Schema handling
covers types and nullability via type arrays, enum sets, properties, required
sets, additionalProperties, numeric/length/item/property bounds, compositions,
and local `$ref` targets with cycle protection. OpenAPI 3.0's raw keywords
such as `nullable` and boolean `exclusiveMinimum` are compared as JSON,
without 3.0 semantics. External references never trigger I/O.

`max_nodes` defaults to 100000; visited paths, copied parameters, metadata
reference steps, queued work and emitted changes consume the same budget.
Exhaustion emits one `LimitReached` and `complete()` returns false.
Nonpositive budgets permit no work. The queue, matching and reference-pair
maps, and output entry counts are bounded by this budget. Individual JSON
payloads, strings, type/enum sets and linear member scans are bounded by the
already decoded input's size, rather than by its number of work entries.
The walk is iterative
so deep schemas do not grow the comparator call stack. Document conversion
and JSON equality use the core JSON implementation; decode limits should be
applied before comparing untrusted documents. No network or filesystem I/O
is performed by this package.

Only schemas reachable from operations are compared; unused components,
documentation and vendor extensions outside schemas are not API changes.
Server variable definitions, response header requiredness, callbacks/webhooks,
and JSON Schema implication beyond the listed rules are not interpreted.

## Cross-check recorded 2026-11-17

The external provider documents stayed in scratch and were deleted after the
run; none are redistributed here. The source repository was
`gaato/moonbit-sdks`. Both comparators received the same JSON pairs. Runs used
`--network none`, a read-only input mount, no capabilities and
`no-new-privileges`; input was parsed as data. The comparator harness used
`resolver_gate.mbtx --run-with-local-module mttp_core` to load this worktree's
package, decoded with `FromJson`, then called `compare(max_nodes=1000000)`.
Every report completed.

The reference CLI was `tufin/oasdiff:v1.35.0`, pinned for every final run as
`sha256:82b1840a77335562bb11ce95f77ad31745a0c6f3a770929333ed1c5ef466e400`.
`changelog`, `breaking` and `diff` were run with JSON output following the
[official container usage](https://github.com/oasdiff/oasdiff/blob/main/docs/DOCKER.md).
The earlier v1.11.7 trial refused Anthropic's numeric `exclusiveMinimum`;
that tool limitation is why the final cross-check used v1.35.0.

| Pair | Source revisions, old → new | This package, request / response changes | oasdiff changelog / breaking |
|---|---|---:|---:|
| GitHub `github/spec/api.github.com.2022-11-28.yaml` | `9d591c17c86d` → `f8bd748186d0` | 3 / 7, zero breaking in either view | 45 / 0 |
| OpenAI `openai/spec/openai.yaml` | `9d591c17c86d` → `f8bd748186d0` | 0 / 0 | 0 / 0 |
| Anthropic `anthropic/spec/anthropic.json` | `1ca1bc6c073f` → `f8bd748186d0` | 12 / 22, zero breaking in either view | 45 / 10 |
| Hand-written GET, required query added, response enum expanded, raw `nullable: false → true` | two small OpenAPI 3.0.3 documents | 1 / 2, Client breaking 2, Server breaking 1 | 3 / 3 |
| Hand-written POST, request body became required, minimum increased and maximum decreased | two small OpenAPI 3.1.0 documents | 3 / 0, breaking 3 in both views | breaking 3 |

YAML conversion used `mikefarah/yq:4.47.2`, pinned as
`sha256:76def1f56f456ecc1c3173ea275218ee17139bc2018c5a07887b15afd88ec03e`.
OpenAI includes an integer outside signed 64-bit range; yq's direct JSON
conversion refused it. Conversion assigned YAML integer nodes the float tag
before emitting JSON (`(.. | select(tag == "!!int")) tag = "!!float"`).
Numbers were therefore represented with double precision, which is also the
core JSON model used by this package. This limits conclusions about exact
large integer values. OpenAI has only the initial original-spec import in
its history; its originals in these two revisions are identical.

Anthropic's originals lack mandatory `info.version`. The raw `FromJson`
trial failed with `JsonDecodeError((/info/version, missing required field))`.
For the additional comparison only, both decoded JSON objects received the
same `info.version = "corpus-placeholder"` in memory before `FromJson`.
oasdiff accepted the unchanged originals. The placeholder cannot affect
these changes because this package ignores `info` metadata. This is an
explicit input admission limitation, not a successful raw decoding claim.

Disagreements and their causes:

- GitHub: this package reports shared schema changes once per side, whereas
  oasdiff expands them at operations (38 response optional-property additions,
  four newly required response properties, two optional request properties
  and one endpoint). Both classify the pair as having no breaking changes.
  The check exposed a path-matching bug: an exact path must win over a sibling
  with a different capture name and the same shape. A regression test pins it.
- Anthropic: this package reports 20 raw annotation/extension changes, 12
  property additions and two required-property additions. oasdiff matches
  changed `anyOf` members as removals/additions, including Model members whose
  descriptions changed, and marks six request removals and four response
  additions breaking. This package pairs composition members by index and
  reports the changed annotations as warnings. Reordered compositions can
  consequently produce conservative positional differences; neither count
  is a proof of schema implication. Shared-target deduplication also explains
  the different property counts.
- Hand-written pair: both detect the required query parameter and new response
  enum case. oasdiff additionally interprets 3.0 `nullable` as breaking;
  this package intentionally reports it as `KeywordChanged`/Warning. In the
  Server view the response enum expansion is Info, as the API requires.
  In the second hand-written pair, both tools identify all three request
  restrictions as breaking.

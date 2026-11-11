# mttp design

**Status: rebuilt on 2026-11-08.** The design accepted on 2026-10-24 was implemented on branch `ccr-eae554e2-r0xapl-u1` (PR #2, head `1ea1b3b`). The 2026-11-08 decisions in §0.1 split its lower half into a stable, separately versioned `gaato/http` 0.6, rename the I/O module to `gaato/http-async`, and move the runtime to `moonbitlang/core/async` now. Where an older passage disagrees with §0.1, §0.1 wins. On 2026-11-11 the family took its final form (§0.0): gaato/http folded into gaato/mttp, gaato/http-async became gaato/mttp_async with the app's entry, and §0.0 wins over everything below it.

PR #2 is the **reference branch**: its code, tests and measurements are the source for the rebuild, component by component (§7.2), but it is not merged. Its status notes (`design/implementation-status.md`, `design/validation.md`) describe that branch and are not carried over. The contracts of its two follow-up documents (portable engines; typed responses) are folded into this document: §5.11 (layers), §4.4 and §4.7 (Result-based responses), CONTRACT.md (ports and attempts).

Items still marked **[needs-prototype]** are settled during implementation; remaining **[proposed]** items are the defaults. Public signatures are generated in each package's `.mbti` file once the package lands; the sketches here are the intent.

> **Note on paths and history.** §10 records facts verified in October 2026 with prototypes built in a temporary session directory (`wf2/*`, `wf3/rev`, `v4/*`), on moonc 0.10.16 and 0.10.17, before core/async shipped. Those prototypes are kept as sources on branch `ccr-eae554e2-r0xapl-seeds` (and `wf3/rev` as `design/prototype/` on `ccr-eae554e2-r0xapl-prototype`, commit 105d062). Package names in §10 (`mttp-net`, `@model`, `@clock`) are the names of the time; §4 gives the current ones.

| Prototype | Path (under the October session's scratchpad) | Result |
|---|---|---|
| Revised design, end to end (model, clock, client, schema, endpoint, endpoint/testkit, router, apispec, openapi, testing, an app with a definition package and e2e tests) | `wf3/rev` | 31/31 on wasm-gc, js, native and wasm with moonc 0.10.16 and 0.10.17 |
| Integration prototype of the first architecture | `wf2/integration` | 27/27 on 4 targets |
| v0.1-sized client | `wf2/scope/v01` | 4/4 |
| Resolver experiments (isolated MOON_HOME, fake registry) | `wf2/resolver` | §10 |
| Runtime adapters (moonbitlang/async 0.22.5 and core-main async) | `wf2/runtime` | §10 |
| Completeness probes (schema, outputs, regex, security) | `wf2/completeness` | 4 targets × 2 toolchains |
| Consumer ports (discord REST, GitHub, OpenAI SSE, URL join, bridge) | `wf2/consumer-migration` | 4 targets × 2 toolchains |
| Final-review probes | `v4/ne`, `v4/rev` | F52–F54 |

Toolchain now: MoonBit 0.10.20 (`moon version --all` reports `0.10.20+65efd5b93`), the first stable release with `moonbitlang/core/async`. It is pinned; `moon self-update` is not used, and newer toolchains are tried by canaries only (§5.6).

---

## 0. Decisions

### 0.0 Final form (2026-11-11)

Decided by the owner on 2026-11-11 after a review from first principles. Where §0.1, §0.2 or a later section disagrees, this section wins. Sections 1–6 already use the names below; §7–§10 are kept as records of the rebuild and keep the names of their time.

**Criteria.** Every structural choice follows from these; a change is reopened only when one of them is found broken or a new fact appears.

1. **Who chooses it**: MoonBit users who outgrow `moonbitlang/core/async/http`: API clients and SDKs, long-running services, typed APIs with OpenAPI. Simple GETs are left to the standard library. What the family offers on top: policy (retries under a budget, deadlines, rate limits, redirects, cookies), typed errors, typed endpoints with OpenAPI, and an I/O-free core tested identically on four targets. Bounded parsing is not a selling point once core fixes its #4612 P0-2 findings.
2. **Quality is the entry ticket**: bounded defaults, deterministic tests and the gates stay.
3. **One module per job** for an app, whose first example fits in about ten lines compiled in CI; no experimental opt-in on a recommended path.
4. **Libraries carry no I/O**: an SDK depends on no I/O module, builds on wasm-gc, and does not re-release when the runtime or a codec changes.
5. **Module boundaries only by principle 8.** In this family the only boundary with a reason is I/O. Package boundaries follow dependencies.
6. **Names**: every module carries the brand `mttp`; each description names the job; the first line of each README routes the reader.
7. **Experimental only for a concrete reason** (a planned break, a compiler-internal dependency).
8. **Nothing left open without a reason**: an improvement is done or declined with its reason; only items waiting on an outside fact stay open, and say what they wait for.

**Modules.**

| Module | Holds | Who adds it |
|---|---|---|
| `gaato/mttp` 0.2 | Everything without I/O: the vocabulary (root package, `@mttp`), `rt`, `h1`, `h1client`, `h1server`, `driver`, `sim` (formerly gaato/http), the client and its policy, `sse`, `multipart`, `cookie`, `jsonkit`, `schema`, `testing`, and the endpoint layer (`endpoint`, `endpoint/testkit`, `router`, `apispec`, `openapi`) | Libraries (SDKs), and code that shares endpoint definitions on wasm-gc |
| `gaato/mttp_async` 0.1 | I/O on moonbitlang/core/async (formerly gaato/http-async: `backend`, `runtime`, `codings`, `conn`, `server`, `fetch`, `hosts`, `trust`) and the app's entry in its root: `run`, `client()` and re-exports | Apps; the only module in their moon.mod |
| `gaato/mttp_digest` 0.2 | Digest authentication (moonbitlang/x for crypto) | Apps that need Digest |

- gaato/http and gaato/http-async are deprecated with a pointer to these; gaato/requesto's and gaato/req's deprecation reasons point to gaato/mttp_async (`moon deprecate --reason` rewrites them).
- **No neutral HTTP layer of our own.** A runtime-independent HTTP vocabulary belongs in the standard library (Go's net/http, the Web platform's Request/Response); today core's HTTP types live inside `core/async/http`. It is proposed upstream in a new issue referencing #4613 and #4686; if core adopts one, gaato/mttp moves onto it.
- **sttp mapping**: sttp-model → mttp's root, sse, multipart, cookie; client4 core → `mttp/client`; client4 backends → mttp_async (core/async) or any other module implementing `Backend` or the `rt` ports; tapir core, server and stub → `endpoint`, `router`, `endpoint/testkit`; sttp-apispec and openapi-docs → `apispec`, `openapi`. Differences: three modules, not a dozen (MoonBit compiles only imported packages, and every 0.x module adds version coordination); the core has no default backend (ours needs a runtime and codecs, the JVM's HttpClient needs nothing); one client, so the client interpreter stays in `endpoint`; no sttp-shared (direct-style async); an HTTP/1.1 engine of our own (no neutral one exists in MoonBit).
- **The entry** (`gaato/mttp_async` root): `run(async fn)` starts core/async's loop without the app importing core/async. `client()` builds a Client over AsyncBackend with `RetryPolicy::conservative()` under a `RetryBudget` (retries on by default, as API SDKs and ky do; the budget keeps retries within 20 % of recent requests plus 10 per second), a 30 s attempt and 120 s call deadline, FollowRedirects (10 hops) and decompression. The root re-exports the vocabulary and the client API an app uses; serving goes through `gaato/mttp_async/server` and a Router's handler.
- **Graduated**: endpoint, endpoint/testkit, router, apispec, openapi, h1client and h1server are no longer experimental. `driver` stays experimental: it relies on the compiler's `%async` intrinsics. apispec types OpenAPI 3.2's fields now, unset in 3.1 documents, because a struct cannot be `#non_exhaustive`.
- **Declined, with reasons** (§12 keeps only what waits on outside facts):
  - SDKs emitting Endpoint values: OpenAPI documents of third-party APIs come from their providers and the SDKs are generated from them; `BackendStub` already fakes them in tests; the SDKs' public API would be tied to the endpoint layer's.
  - AsyncAPI: there is nothing to describe (no WebSockets; SSE is described with `itemSchema`).
  - An endpoint core without the client (as tapir-core is without sttp's client): the client interpreter uses the endpoint's private internals, so separating it would freeze them as a public API and turn `ep.request(...)` into a function; it saves only one package's compile for server-only users, and the family has one client while tapir has several.
  - Reporting core/async/http's head bound and CL+TE handling: core's own review tracks both as P0-2 with reproductions.
- **Waiting on outside facts**: OpenAPI 3.2 output (code generators and Redoc cannot read 3.2 yet); WebSockets (core/async's websocket lacks bounds and masking checks, X-06); HTTP/2 (core/tls has no ALPN). Backends on other runtimes (moonbitstack's moonfetch would bring HTTP/2 and 3) wait for those libraries to move off moonbitlang/async 0.22, which cannot share a program with core/async.


### 0.1 Rebuild (2026-11-08)

Made by the user on 2026-11-08. They supersede the 2026-10-24 rows marked † in §0.2 and anything below that says otherwise.

| Topic | Decision | Replaces |
|---|---|---|
| Lower layer | **`gaato/http` 0.6.0**, the breaking successor of the published mbt-sdk `gaato/http` 0.5. It holds the wire vocabulary, the runtime ports, the h1 codec, the client and server connection engines and the `Backend` trait. It depends on moonbitlang/core only and builds on all four targets. Nothing of 0.5's own packages is carried over: retry, sse, cookie, multipart, Retry-After and Link parsing already live in mttp, and Transport plus middleware are replaced by `Backend` and wrappers. | §5.8 "gaato/http never gets a 0.6"; M-01; the `model`, `clock`, `conn` and `h1` packages of gaato/mttp |
| I/O module | **`gaato/http-async` 0.6.0**, renamed from `gaato/mttp-net` (never published). It depends on gaato/http, `moonbitlang/core/async` and the codec modules, **not on gaato/mttp**. mttp and http-async share only gaato/http, so either can take a minor release without the other (this removes the F29 problem, M-09). | §0.2 "Module names"; M-04, M-09, Q5, Q6 |
| Policy layer | **`gaato/mttp` 0.1.0** depends on gaato/http and core only: client, retry, rate limits, cookies, SSE reader, multipart, schema, endpoint, router, OpenAPI, test stubs. **`gaato/mttp_digest` 0.1.0** stays as it is. | M-01 |
| Facade | **`quick` is dropped**, together with `client.quick_request` and the root `new_client` factory. One-liners belong to `moonbitlang/core/async/http`. That client has no bound on the response head, accepts Content-Length together with Transfer-Encoding and decodes only gzip, so it is for trusted, throwaway use only; this document and the READMEs say so. | §0.2 "Facade"; M-06, Q3 |
| Why core/async/http is not the foundation | No head-size bound, CL+TE accepted, gzip only, connection reuse still provisional (F65). A general lower layer cannot be built on it; gaato/http keeps its own codec and engines and uses core/async only through http-async's adapters. | — |
| Runtime | **Stage R executes now**, on MoonBit 0.10.20 and `moonbitlang/core/async`. `moonbitlang/async` is forbidden in every module (gate, §5.13). Old-stack graphs (anything still on gaato/http ≤ 0.5 or http-async ≤ 0.5) are frozen: they are not patched onto core/async (Q15, G-06 answered with option (b)). | the former Stage R; G-06, Q15 |
| Metadata | Request and response metadata stay `Attributes` with typed keys. MoonBit has no TypeId, so a type-keyed map in the style of hyper's Extensions cannot be built soundly. | — |
| Compression | Engines move raw bytes only. Decoding is the `@codings.Decompress` Backend wrapper, encoding the `@codings.compress` Handler wrapper, both in http-async. Bounds are two-level: the engine counts wire bytes, the mttp Client counts decoded bytes (§5.2). | C-13 (`decompress` option) |
| Experimental packages | A stable module may hold experimental packages. They declare `options(experimental: true)` in moon.pkg, and every importer opts in by listing them, as in `options("allow-experimental-packages": ["gaato/http/h1client"])` (list form only; `true` is refused by the gate; the workspace PR confirms the list form). gaato/http's `h1client`, `h1server` and `driver` start experimental, and so do mttp's endpoint layer, router, apispec and openapi. | principle 8 (old) |
| PRs | **PR #2 is superseded** by a stack of PRs from `main`, each ≲ 5k lines and passing every gate on its own (§7.1). They merge after the gates pass and the Codex review findings are resolved. PR #2 is closed with a link to the stack; its branch stays as the reference. Nothing is published from the PRs; publishing is a separate, owner-approved train (§8.2). | §0.2 "PRs" (kept in spirit) |
| Rewrite or keep | Chosen per component by quality, from "move as is" to "rewrite" (§7.2). Starting from zero is allowed where the reference is weak. | — |
| Toolchain | 0.10.20+65efd5b93, pinned. The `%async` intrinsics used by the Driver exist in 0.10.20 and are confined to one file (§5.6). | §5.6 toolchain pins |
| OpenAPI version | (2026-11-11) **3.1 now, ready for 3.2.** Code generators cannot read 3.2 yet: openapi-generator's parser, swagger-parser 2.1.48, rejects a 3.2 document, and Redoc reads up to 3.1. A document other languages cannot generate clients from loses the point of one definition for server, client and docs. Ready for 3.2 means each sequential item is already described in 3.2's shape: an SSE event is `x-oai-itemSchema` (the OpenAPI Initiative's registered extension for `itemSchema` before 3.2) with string `event`/`data`/`id`, integer `retry` and the JSON payload as `contentSchema` of `data`. Moving to 3.2 renames that member to `itemSchema` and changes the version field. | P-11 (3.1-only needs-user-input), the OpenAPI half of open question 2 (§12), `x-mttp-sse-data-schema` |

### 0.2 Original decisions (2026-10-24)

Made by the user on 2026-10-24; they superseded the corresponding [needs-user-input] items. Rows marked † are superseded by §0.1.

| Topic | Decision | Replaces |
|---|---|---|
| Scope | v0.1–v0.4 are implemented; the endpoint layer, router, openapi and the test toolkit ship as **experimental** in 0.1.x, outside the §5.6 freeze. WebSockets are deferred (see X-06). | V-01, Q1, Q12 |
| PRs † | This document lands on its own; the implementation follows as stacked PRs, one per review unit (≲ 5k lines, fully gated). Merge commits. Nothing is published from them. | — |
| `Request.url` | `String`. The raw string is refused if it contains space, CR, LF or other controls (before parsing: the WHATWG parser strips them), then parsed strictly at send time; the engine re-serialises the request target from the parsed form and validates headers. No URL type exists in core or core/async. | X-01, Q2 |
| Module names † | `gaato/mttp`, `gaato/mttp-net`, and `gaato/mttp_digest`. Later third-party integrations follow sttp/tapir: `gaato/mttp-<lib>-backend`, `gaato/mttp-<lib>-server`. The tapir-equivalent packages stay inside `gaato/mttp`. (Still valid: the Digest module, renamed `gaato/mttp_digest` before its first publish because a library's last path segment is its default import alias and `-` is not valid in one; the naming of later integrations; the tapir packages in mttp.) | M-04, M-07, Q6 |
| Facade † | `mttp-net/quick` and `client.quick_request(req)`; requesto deprecated later. (Still valid: requesto is deprecated and its keyword-argument API is not carried over.) | M-06, Q3 |
| jsonkit | `gaato/mttp/jsonkit`. | M-03 |
| Shim | None (G-02 default (d)). | G-02, Q4 |
| Server | 400 for invalid bodies; credentials first. | P-04, P-05, Q7, Q8 |
| WebSockets | Not now: core/async's websocket lacks size bounds, aborts on misuse, needs a concurrent reader for ping, never waits for the peer's Close, validates UTF-8 loosely, sends a fixed 101 header set, has no js/wasm-gc support, and upgrades only core/async/http's `ServerConnection`. Reserved hooks: `Response.attributes`, an internal 101 hand-off in the h1 server engine, no compression on 101, no runtime type in any public signature. | X-06, Q12 |
| Test architecture † | A runtime-free deterministic driver and contract-bound doubles; no `async test` in the portable modules; VirtualClock redesigned. (Still valid in substance; the Driver now lives in `gaato/http/driver` and the doubles in `gaato/http/sim`, §4.10.) | §4.10, §5.7 |

## 1. Goals and non-goals

| Goals | Non-goals |
|---|---|
| An HTTP library family that MoonBit users pick when they outgrow the standard library's HTTP (§0.0), with sttp's split of responsibilities: vocabulary (sttp-model), client (client4), endpoint descriptions with server and client interpreters (tapir), and a spec model (sttp-apispec) | sttp's type machinery: F[_], capability type parameters, a sttp-shared layer |
| A runtime-free core (`gaato/mttp`) that libraries build on, so an app chooses the I/O | A second runtime, or code that runs on two event loops in one process |
| Sans-IO by default: every package except `gaato/mttp_async` builds and tests on wasm-gc, wasm, js and native | Building on `moonbitlang/core/async/http` (§0.1) |
| Move gaato's existing consumers (discord, discord_voice, discord-cli, openai, anthropic, github, codex-protocol, kbbi, nekosama, profile-readme) onto one stack, with one retry loop, one error pair and one transport trait | Keeping sdk-runtime, requesto, gaato/http or gaato/http-async as parallel long-term APIs; a neutral HTTP vocabulary of our own (it belongs in the standard library) |
| Keep gaato's strengths: injected clock and randomness; bounded-by-default with ledgers; phase-tagged errors with `is_unsent`; the incremental SSE parser; deterministic tests on every target | HTTP/2 and ALPN (core/tls has no ALPN), server TLS, AsyncAPI and WebSockets |

## 2. Principles

1. **sttp's split of responsibilities, not its types.** The layers are vocabulary, client, endpoint description, interpreters and spec model.
2. **Sans-IO by default.** Only `gaato/mttp_async` touches sockets, the event loop, TLS or JS host objects. gaato/mttp is runtime-free; their async code is tested through the runtime-free Driver (`@driver.run_sync`).
3. **Injected nondeterminism.** Clock, Timer, Gate, Dialer, Coordination and randomness are always passed in. No code reads wall time or calls a global RNG.
4. **Bounded by default; refuse rather than degrade.** Every bound has a RESOURCE_BOUNDS row naming a test (§7.1).
5. **Transport failures carry their phase.** `is_unsent` decides whether a non-idempotent request may be resent.
6. **One mechanism per concern.** One sending path (`Client::send`), one wrapper form (a `Backend` struct, or `from_fn`), one attempt deadline, one bucket channel, one body direction (pull), one response type for both directions, one definition checker, one framing function for both engines. §5.10 lists the mechanisms that were removed.
7. **Codegen is optional.** Generated code is code a person could write by hand.
8. **A module boundary needs one of two reasons:** (a) an **external dependency**, because a module's imports reach every consumer's download set and version selection (F31); or (b) an **independent version cadence**, such as a stable lower layer under an experimental upper one (a split isolates consumers' versions only if the parts are versioned independently, F32). Target isolation is *not* a reason: per-package `supported_targets` does it inside one module (F17). Inside a stable module, an experimental package sets `experimental: true` in its moon.pkg, and each importer opts in with the list form of `allow-experimental-packages`; the gate refuses `true`.
9. **No public signature names a runtime type.** This covers moonbitlang/core/async's `TaskGroup`, `@io.BinaryReader`/`BinaryWriter`, `@socket.Tcp`, `@tls.Tls` and every `@js_async.*` type, and it applies to gaato/mttp and gaato/mttp_async alike (gaato/mttp_digest has no async adapter to leak). Ports are traits in `gaato/mttp/rt`; adapters implement them privately. This keeps signatures stable across runtime changes; it does not keep consumers' manifests stable (an `async fn main` still imports the runtime).
10. **Evolution rules from the first release.** Every `pub(all)` enum that may grow is `#non_exhaustive`. `pub(all)` struct field sets are frozen at release, and users build these structs through `::new`/`::default()` plus record update. Suberrors cannot be made non-exhaustive, so a suberror that may grow carries a `#non_exhaustive` kind enum; every other suberror is frozen at release (§5.6).
11. **Three layers inside the engines** (§5.11): pure decisions over persistent snapshots, local orchestration over injected ports, and runtime adapters. Effects never enter the pure layer, and adapters commit a new state before acting on it.
12. **Expected failures are values.** A rejected status or an undecodable body is a `Result` value; transport failures, cancellation and unknown user errors stay effects with their identity (§4.4).

## 3. Module and package map

### 3.1 Modules

| Module | Kind | Depends on | Why it is a module (principle 8) |
|---|---|---|---|
| `gaato/mttp` 0.2 | the runtime-free core; wasm-gc, wasm, js, native | moonbitlang/core only; never `core/async*` or `core/compress*` | (a) Libraries depend on it without taking the runtime or the codecs. |
| `gaato/mttp_async` 0.1 | the only I/O module and the app's entry; native, wasm, js | gaato/mttp, moonbitlang/core (incl. `core/async`, opted in), gaato/codec_bytes, gaato/deflate, gaato/brotli, gaato/zstd | (a) External dependencies (codecs) and the one runtime. |
| `gaato/mttp_digest` 0.2 | Digest authentication wrapper | gaato/mttp, moonbitlang/x | (a) Crypto dependency; it must not reach every mttp consumer. |
| `gaato/mttp-gen` | tool, **later** | moonbitlang/parser | A tool, installed with `moon install`, never listed in any moon.mod (F51). Dropped until a consumer needs it. |

Unpublished members of the workspace (`moon.work`): `conformance` (corpora, ledgers, cross-layer e2e suite), `examples` (`get`, `serve`, `fetch`) and `benchmarks`. Socket and adversarial suites live inside mttp_async's own packages as native/wasm tests.

Retired or replaced paths:

| Path | Fate |
|---|---|
| `gaato/http` ≤ 0.6 | Folded into gaato/mttp 0.2 (§0.0); deprecated. |
| `gaato/http-async` ≤ 0.6 | Renamed gaato/mttp_async 0.1 (§0.0); deprecated. |
| `gaato/sdk-runtime` | Replaced by `gaato/mttp/client`; deprecated after the SDKs moved. |
| `gaato/requesto`, `gaato/req` | Deprecated; the reason points to gaato/mttp_async. |
| `gaato/mttp-net` | Never published; the name is dropped. |

`gaato/clock` and `gaato/jsonkit` are not modules: the ports are packages of gaato/mttp (`rt`) and jsonkit is a package of gaato/mttp. A consumer compiles only the packages it imports (F18).

### 3.2 Packages of gaato/mttp: vocabulary, codec, engines

All build on all four targets. "Status" is the package's stability inside the stable module.

| Package | Status | Responsibility | Source in PR #2 |
|---|---|---|---|
| root `@mttp` | stable | Method, Headers, Url (WPT parser), Request/Response (+ heads), Body/StreamBody/BodyStream, TransportError (Kind, Phase, `is_unsent`), Attributes, Handler, URL/form/date helpers. **New:** `trait Backend`, `SendOptions`, `BodyTiming` (§4.2) | `mttp/model`; Backend from `mttp/client` |
| `rt` | stable | Port traits: Clock, Timer, Gate, Conn, Dialer, Signal, Coordination; `default_random` | `mttp/clock`, `mttp/conn` |
| `h1` | stable | Sans-IO HTTP/1.1 codec: HeadDecoder, `scan_head`, `parse_request_head`/`parse_response_head` returning named structs `ParsedRequest`/`ParsedResponse`, framing, ChunkedDecoder, wire writers, `Limits`, `ParseError` | `mttp/h1` |
| `h1client` | stable | Client connection engine: pool, slots, wire, body, deadlines, proxy CONNECT and NO_PROXY. `Client::new(dialer~, clock~, timer~, coordination~, config~ : ClientConfig)` and `impl @mttp.Backend` | `mttp-net/internal/h1client`, `mttp-net/h1/client` |
| `h1server` | stable | `serve_conn` (one accepted connection, `scheme~` added), `ServerLimits`, `ServerConfigError` (validation only) | `mttp-net/internal/h1server`, `mttp-net/h1`, `mttp-net/h1/server` |
| `internal/control` | internal | Persistent pure state machines: admission, pool metadata, peer EOF/failure, listener lifecycle | `mttp-net/internal/control` |
| `driver` | experimental | Runtime-free deterministic scheduler: `run_sync`, `Driver`, tasks, virtual timers; the only file with `%async` intrinsics | `mttp/testing/driver` |
| `sim` | stable | Port doubles and contract checks: SimConn (`pair`), ScriptedConn, ScriptedDialer, SimCoordination, FakeClock, SimClock, SimGate, Feed, quickcheck generators, `check_splits`, **new** `check_conn`, and the Backend/BodyStream/Coordination contract checkers | `mttp/testing/conn`, `mttp/clock/fake`, `mttp/testing/feed`, `mttp/testing/gen`, the checkers of `mttp/testing` |
| `internal/form`, `internal/text` | internal | Form and UTF-8 helpers behind the root's public functions | `mttp/internal/*` |

The root package's alias is `@mttp`, so it no longer collides with `moonbitlang/core/async/http`'s `@http`.

### 3.3 Packages of gaato/mttp_async: I/O and the app's entry

Every package that imports core/async lists the exact core/async packages it uses in `allow-experimental-packages`.

| Package | Targets | Responsibility | Source in PR #2 |
|---|---|---|---|
| `runtime` | native, wasm, js | AsyncClock (`@async.sleep`, `now`), ClockTimer (task group + `spawn_bg`), SemaphoreGate (`@semaphore`), RuntimeCoordination (`Cond`), `with_timeout_opt`, VirtualClock, NoQuiescence | `mttp-net/runtime` (rewritten) |
| root | native, wasm, js | The app's entry: `run`, `client()`, re-exports of the vocabulary and the client API (§0.0) | new in the final form |
| `trust` | native, wasm, js | `Trust { System; Insecure; PemFile(String) }`, shared by socket dialers and the cross-target backend constructor; ignored by JS fetch | moved from the root (formerly from `conn`) |
| `conn` | native, wasm | `TcpDialer`: `Tcp::connect_to_host`, then `Tls::client(ConnIo(&Conn), host~, trust~)`, so TLS also runs inside a CONNECT tunnel. Trust comes from the `trust` package; no core type is exposed. `internal/socketconn` adapts a Tcp/Tls to `&@rt.Conn` | `mttp-net/conn`, `mttp-net/internal/socketconn` (rewritten) |
| `server` | native, wasm | Listener: TcpServer accepts and hands each connection to `@h1server.serve_conn`. Bind and accept failures are `ListenError` | `mttp-net/server` (rewritten; tests kept) |
| `backend` | native, wasm, js | One type, `AsyncBackend`: on native/wasm the h1client engine + TcpDialer + Decompress; on js `fetch` over core's js_async. `impl @mttp.Backend` | `mttp-net/backend` |
| `codings` | native, wasm, js | Bounded ContentDecoder/ContentEncoder, coding plans, negotiation; **new** `Decompress` (Backend wrapper) and `compress` (Handler wrapper) | `mttp-net/codings` |
| `fetch` | js | Host-neutral `fetch_handler(handler)(req, background)` | `mttp-net/fetch` |
| `hosts` | js | JS entry shims for Workers, Fastly, Vercel, Deno, Bun and AWS Lambda URLs | `mttp-net/fetch` host shims |

### 3.4 Packages of gaato/mttp: client, schema and endpoint layer; gaato/mttp_digest

All of gaato/mttp builds on all four targets. The tiers of the 2026-10-24 design (v0.1–v0.4) are all in mttp; the endpoint layer graduated from experimental on 2026-11-11 (§0.0).

| Package | Responsibility | sttp/tapir counterpart |
|---|---|---|
| `jsonkit` | Presence, ObjBuilder, field helpers, open enums | — |
| `sse` | SseEvent, incremental SseParser, encoder | sttp-model sse |
| `multipart` | Writer with MultipartError and streaming parts; boundary from injected randomness | sttp-model Part |
| `cookie` | RFC 6265 CookieJar (clock injected); Set-Cookie helpers | CookieWithMeta + storage |
| `client` | RequestPlan/ResponsePlan with Buffered/Streaming modes, Result readers, ResponseFailure, Client (the policy loop), RetryPolicy and typed decisions, RateLimiter, Paginator, FollowRedirects (+ its config), `from_fn`, Retry-After and Link helpers | client4 core, wrappers, RetryWhen |
| `client/retry` | Retry decisions as data | RetryWhen |
| `client/ratelimit` | WindowLimiter, Pace, GlobalWindow, LimitScope, rate_limit_headers | — |
| `client/cookies` | The `Cookies` Backend wrapper | client4 cookie handling |
| `testing` | BackendStub (`expect`/`when`/`sent`/`verify`), Canned, Recorded, `fail_sends` | client4 testing |
| `schema` | Schema (JSON Schema 2020-12 + defs), Issue, DecodeFailure, Validator, TextCodec, JsonCodec, BodyCodec | tapir Codec, Schema, Validator |
| `endpoint` | Inputs, outputs, declared errors, Endpoint builders with a response mode, server dispatch, client interpreter, definition checker | tapir core + interpreters |
| `endpoint/testkit` | `when_endpoint`, `verify` | tapir stub / verifier |
| `router` | Router, ServerOptions, Middleware, problem+json, CORS, `impl @mttp.Backend for Router` | tapir server core + stub server |
| `apispec`, `openapi` | Typed OpenAPI model (3.1 fields, plus 3.2's left unset); `to_openapi`, `docs_endpoint`, `check_documented` | sttp-apispec, tapir openapi-docs |
| `internal/form`, `internal/text` | Helpers for schema, which imports no HTTP vocabulary | — |

`gaato/mttp_digest` (root package): `DigestScheme` as an origin-scoped Backend wrapper, ported from requesto.

### 3.5 Responsibility rules

- **gaato/mttp's vocabulary, codec and engines** own the wire. **They hold no policy**: no retry, no redirect following, no cookies, no rate limits, no content-coding negotiation, no decoded-body limits.
  - **root** names things on the wire and defines `Backend`. No I/O, no codec beyond HTTP syntax.
  - **rt** defines what the engines need from a runtime; it implements nothing.
  - **h1** turns bytes into heads and framing, and heads into bytes. No connections.
  - **h1client / h1server** drive one or many connections over `rt` ports, with wire-level bounds and deadlines. They never import codings.
  - **internal/control** decides; it never acts.
  - **driver / sim** are test infrastructure. No production package imports them (gate).
- **gaato/mttp's client and endpoint layer** own policy and descriptions. A client policy goes in one of three places:
  - a **Backend wrapper**, if it needs only the request and the response head: redirects, cookies, header injection, wire logging, Digest;
  - the **Client loop**, if it must see the read outcome or pair work across one attempt: retry, rate-limit admission and release, deadlines, decoded-body limits, the attempt observer;
  - the **Client defaults**: base URL, default headers, default SendOptions.
  - **schema** converts and describes values; it knows nothing about HTTP. **endpoint** describes operations and interprets one endpoint on both sides. **router** chooses the endpoint and applies server-wide policy; it is a Handler and a Backend. **apispec** is document data; **openapi** projects endpoints onto it. **testing** and **endpoint/testkit** hold doubles and checkers.
- **gaato/mttp_async** owns the runtime, sockets, TLS, JS host objects and compression. It adapts; it adds no HTTP policy beyond content codings, except the entry's default wiring (`client()`), which only chooses among gaato/mttp's policies.

### 3.6 Dependency diagram

```
moonbitlang/core
   │
   ▼
gaato/mttp  (core only; wasm-gc, wasm, js, native)        (A ──► B means "A imports B")
   rt                          (core only)
   root (@mttp) ──► internal/form, internal/text
   h1 ──► root
   internal/control            (core only; no async, no mut, no Ref)
   h1client ──► root, rt, h1, internal/control
   h1server ──► root, rt, h1, internal/control
   driver                      (core only; %async intrinsics in one file)  [experimental]
   sim ──► root, rt, driver
   jsonkit                     (core json only)
   sse, multipart, cookie ──► root (+ rt for cookie)
   client/retry ──► root
   client ──► root, rt, sse, client/retry
   client/ratelimit ──► client, rt
   client/cookies ──► client, cookie
   testing ──► root, client
   schema ──► jsonkit, internal/*                           (no HTTP vocabulary)
   endpoint ──► root, schema, client
   router ──► root, schema, client, endpoint
   endpoint/testkit ──► root, client, endpoint, router, testing
   apispec                     (core json only)
   openapi ──► root, schema, endpoint, apispec

gaato/mttp_digest ──► gaato/mttp (root, client), moonbitlang/x

gaato/mttp_async ──► gaato/mttp
   trust                       (core only)
   runtime ──► rt + core/async
   conn ──► rt, trust + core/async (socket, tls)
   codings ──► root + codec modules                          (all 4 targets)
   backend ──► h1client, conn, runtime, codings, trust (native/wasm); js_async fetch (js)
   server ──► h1server, conn, runtime, codings
   fetch, hosts ──► root + js_async                          (js)
   root (entry) ──► backend, runtime, trust, mttp root, client, h1client + core/async

libraries ──► gaato/mttp: gaato/{openai,anthropic,github}, codex-protocol
apps and I/O libraries ──► gaato/mttp_async (+ gaato/mttp for its other packages):
           gaato/discord, discord_voice, discord-cli, kbbi, nekosama, profile-readme
tools (never imported): mbt-sdk tools/gen (Python)
```

Rules: an endpoint-definition package imports only gaato/mttp's root, `schema` and `endpoint`, never mttp_async, so it checks on wasm-gc. Every package that imports a target-restricted package declares `supported_targets` itself (F17). Every package that imports an experimental package lists it in `allow-experimental-packages`.

### 3.7 Consumer manifests

Packages of a transitive module cannot be imported (F31), but a re-export (`pub using`) can be used across modules (verified 2026-11-11). So an app lists only `gaato/mttp_async`: its root re-exports the vocabulary and the client API, and `run` spares the app the core/async import and opt-in. An app that uses other gaato/mttp packages directly (the endpoint layer, `schema`, `sse`) lists `gaato/mttp` too. A library lists `gaato/mttp` only; one that does I/O itself (discord's gateway and interactions listener) lists `gaato/mttp_async` as well. gaato/mttp_digest lists gaato/mttp.

## 4. Layer-by-layer design

The sketches use 0.10.20 syntax with bodies omitted. Unless marked otherwise, a signature is the one PR #2 compiled under its old package name, moved to the package given in §3; `(new)` means designed but not yet compiled anywhere. The `#non_exhaustive` attributes and read-only visibilities required by the evolution rules (§5.6) are applied throughout.

Names used in PR #2, §8 and §10, and their homes now:

| PR #2 / earlier text | Now |
|---|---|
| `@model` (`gaato/mttp/model`) | `@http` (gaato/mttp root) |
| `@clock` (`gaato/mttp/clock`), `@conn` (`gaato/mttp/conn`) | `@rt` (`gaato/mttp/rt`) |
| `clock/fake`, `testing/conn`, `testing/feed`, `testing/gen`, contract checkers of `testing` | `@sim` (`gaato/mttp/sim`) |
| `testing/driver`, `testing.run_sync` | `@driver` (`gaato/mttp/driver`) |
| `gaato/mttp/h1` | `@h1` (`gaato/mttp/h1`) |
| `mttp-net/internal/h1client`, `mttp-net/h1/client.H1Backend`, `mttp-net/backend.H1Backend` | `@h1client.Client` (`gaato/mttp/h1client`) |
| `mttp-net/internal/h1server`, `mttp-net/h1` (ServerLimits, ServerConfigError), `mttp-net/h1/server.serve_conn` | `@h1server` (`gaato/mttp/h1server`) |
| `mttp-net/internal/control` | `gaato/mttp/internal/control` |
| `@client.Backend`, `@client.RequestOptions` | `@mttp.Backend`, `@mttp.SendOptions` + `@mttp.BodyTiming` |
| `ServeError`, `ServerConfigError::{Bind, Accept}` | `@mttp.TransportError`; `@server.ListenError` |
| any other `mttp-net/<pkg>` | `gaato/mttp_async/<pkg>` |
| `mttp-net/quick`, `client.quick_request`, root `new_client` | removed (§0.1) |

### 4.1 rt, sim and jsonkit

```moonbit
// gaato/mttp/rt — ports; implemented by gaato/mttp/sim (tests) and gaato/mttp_async/runtime, conn (real)
pub(open) trait Clock { async fn sleep(Self, Int) -> Unit noraise; fn now_unix_ms(Self) -> Int64 }
pub(open) trait Timer { async fn within(Self, Int, async () -> Unit noraise) -> Bool noraise }
pub(open) trait Gate  { async fn acquire(Self) -> Unit noraise; fn release(Self) -> Unit }
pub(open) trait Conn {
  async fn read(Self, max_len~ : Int) -> Bytes? raise @mttp.TransportError
  async fn write(Self, Bytes) -> Unit raise @mttp.TransportError
  fn close(Self) -> Unit
}
pub(open) trait Dialer {
  async fn connect(Self, host~ : String, port~ : Int) -> &Conn raise @mttp.TransportError
  async fn start_tls(Self, &Conn, host~ : String) -> &Conn raise @mttp.TransportError
}
pub(open) trait Signal { async fn wait(Self) -> Unit noraise; fn notify(Self) -> Unit }
pub(open) trait Coordination {
  fn signal(Self) -> &Signal
  async fn supervise(Self, primary~ : async () -> Unit raise @mttp.TransportError,
    monitor~ : async () -> Unit raise @mttp.TransportError) -> Unit raise @mttp.TransportError
}
pub fn default_random() -> Double
```

`rt` imports the root for `TransportError`; the root does not import `rt`, so `Backend` (in the root) names no port. Their rules (sticky EOF, idempotent close, TLS ownership transfer, supervision outcomes, cancellation) are in CONTRACT.md. The traits are new traits with the old names; they are not re-exports of gaato/mttp 0.5's clock traits (G-02).

`sim` holds the doubles: `FakeClock::new(start_unix_ms~ : Int64 = 0L)` (a sequential accumulator), `SimClock`/`SimTimer`/`SimGate` sharing a Driver's time, `pair(coordination, chunk_bytes?)` for two SimConn ends with configurable fragmentation and separate write-half shutdown, `ScriptedConn` (read steps: chunk, EOF, failure, wait), `ScriptedDialer`, `SimCoordination::new(driver)`, `Feed` (a scripted BodyStream), quickcheck generators, `check_splits`, and the contract checkers `check_conn` (new name of `check_conn_pair_contract`), `check_coordination_contract`, `check_body_stream_contract` and `check_backend_contract`. The checkers live here, not in mttp, because mttp_async must run them against its own adapters and cannot import mttp. `sim` imports `driver`, so it lists `driver` in `allow-experimental-packages` like any other importer, and its Driver-taking constructors (`SimCoordination::new`, `Feed::new`, SimClock) change only when `driver` does.

`gaato/mttp/jsonkit`: `Presence[T]` (Absent/Null/Value), `ObjBuilder`, `field`, `opt_field`, `presence_field`, `expect_object`, `open_int`, `open_string`. The alias `@json` would collide with core's, hence the name.

### 4.2 gaato/mttp root

```moonbit
#non_exhaustive
pub(all) enum Method { Get; Head; Post; Put; Delete; Connect; Options; Trace; Patch; Other(String) } derive(Eq, Hash, Debug)
pub fn Method::parse(s : String) -> Method                 // to_string, Show, is_idempotent

pub struct Headers { priv pairs : Array[(String, String)] } // immutable, ordered, duplicates kept, case-insensitive lookup
pub fn Headers::of(pairs : ArrayView[(String, String)]) -> Headers   // empty, get, get_all, add, set, remove, iter, length
pub fn Headers::validate(self : Headers) -> Unit raise TransportError // CR/LF/NUL, token names

#non_exhaustive
pub(all) enum Phase { Pool; Dial; Write; Head; Body; Unknown } derive(Eq, Debug)
#non_exhaustive
pub(all) enum Kind { Invalid; Connect; Timeout(ms~ : Int); Network; Protocol; Proxy(status~ : Int)
  TooLarge(limit~ : Int); TooManyRedirects(max~ : Int); RedirectRefused; Unreplayable; Closed } derive(Eq, Debug)
pub(all) suberror TransportError { TransportError(kind~ : Kind, phase~ : Phase, detail~ : String) } derive(Debug)
pub fn TransportError::is_unsent(self : TransportError) -> Bool        // message

pub(open) trait BodyStream { async fn read_some(Self) -> Bytes? raise TransportError; fn close(Self) -> Unit }
pub struct StreamBody { /* take-once cell */ }
pub fn StreamBody::new(s : &BodyStream, length? : Int64) -> StreamBody // take (second take: Unreplayable, Pool), close, length
#non_exhaustive
pub(all) enum Body { Empty; Bytes(Bytes); Stream(StreamBody) }        // Eq (Stream by identity), Debug
pub fn Body::is_replayable(self : Body) -> Bool
pub async fn read_bounded(s : &BodyStream, limit : Int) -> Bytes raise TransportError

pub fn[T] AttributeKey::new(name : String) -> AttributeKey[T]          // Attributes::empty, put, get
pub let remote_addr : AttributeKey[String]                            // set by server adapters
pub let replay_safe : AttributeKey[Bool]                              // "resend is safe even after the write"
pub let background : AttributeKey[(async () -> Unit) -> Unit]         // set by adapters that can run detached work

pub(all) struct Request { meth : Method; url : String; headers : Headers; body : Body; attributes : Attributes }
pub fn Request::new(meth : Method, url : String) -> Request           // get, post, put, patch, delete, options
// header, set_header, bearer, basic, query, body_bytes, body_text, body_json, body_form, body_stream, attribute, head
pub fn is_idempotent(req : Request) -> Bool                           // method, or replay_safe; an Idempotency-Key header alone is not enough
pub(all) struct Response { status : Int; headers : Headers; body : Body; attributes : Attributes }   // both directions
pub fn Response::new(status : Int, headers? : Headers, body? : Body) -> Response   // head, close, closes_connection
pub type Handler = async (Request) -> Response noraise

// URLs and helpers (moved): Url::parse/resolve/path_segments/query_params, join_url, encode_path, append_query,
// retry_after_ms, parse_retry_after, parse_link_next, http dates, percent_*, form_urlencode,
// form_urldecode(max_pairs? = 256), is_success, reason_phrase, UriBuilder/UriPart/Trusted, uri(f)

// (new) the transport seam
pub(open) trait Backend {
  async fn send(Self, Request, SendOptions) -> Response raise TransportError
  fn close(Self) -> Unit = _
}
pub(all) struct SendOptions { timeout_ms : Int?; body : BodyTiming } derive(Eq, Debug)
#non_exhaustive
pub(all) enum BodyTiming {
  Exchange(max_bytes~ : Int)   // the caller reads the whole body inside the attempt: one deadline over head and body,
                               // and at most max_bytes on the wire
  Stream(idle_ms~ : Int?)      // the caller streams: the deadline ends at the head; each later read gets idle_ms
} derive(Eq, Debug)
pub fn SendOptions::default() -> SendOptions   // { timeout_ms: None, body: Exchange(max_bytes=64 MiB) }
```

Design notes:

- **`Request.url : String`** (X-01). Engines parse it once at send time; a bad URL is `TransportError(Invalid, Pool)`, which counts as unsent. Generated SDK code stays non-raising.
- **One `Response` for both directions.** A server closes after a response with `Connection: close`. `Response.attributes` is the response-side channel (redirect history, route template).
- **Stream bodies are taken once** (CONTRACT, BodyStream 3). A second take raises `TransportError(Unreplayable, Pool)`.
- **SendOptions replaces RequestOptions.** The old struct let a caller build meaningless combinations (`read_idle_ms` with a buffered body, a `body_deadline` flag that contradicted the reader, redirect and decoding switches that the engine never read). `BodyTiming` makes the buffered/streaming choice one value, and `Exchange` cannot be built without a byte limit. Policy knobs moved out: redirects to FollowRedirects (§4.4), decoding to `@codings.Decompress` (§4.11).
- **No type-keyed extensions.** `Attributes` with typed keys stays the metadata channel (§0.1).

### 4.3 sse, multipart, cookie

| Package | Contents |
|---|---|
| `sse` | `SseEvent{event, data, id, retry}`, `SseParser::new(max_event_bytes? = 16 MiB)`, `feed`, `finish`, `encode`. On overflow, `feed` and `finish` raise `@mttp.TransportError(TooLarge(limit), Body)`; events completed earlier in the same chunk are delivered first. |
| `multipart` | `body(req, parts, boundary~) -> @mttp.Request raise MultipartError`, `encode_segments_fresh(parts, random~)`, `make_boundary(random)`, streaming parts with ownership rules. `MultipartError` keeps InvalidBoundary, BoundaryCollision, InvalidHeaderValue and StreamPart. A bounded reader comes later. |
| `cookie` | `CookieJar::new(clock, max_per_domain? = 50, max_total? = 3000, is_public_suffix?)`, `SetCookie::to_header`, `parse_cookie_header`. |

### 4.4 client

This section is the accepted Result-based contract (the "typed responses" follow-up of PR #2). It replaces the exception-first `ResponseAs`/`ResponseError` design of 2026-10-24, whose names survive only in §8 and §10.

```moonbit
// response modes: what the description may do with the body
pub(all) struct Buffered {}                 // read inside the attempt; retryable
pub(all) struct Streaming {}                // handed to a callback after the attempt; never replayed
pub(open) trait ResponseMode { /* sealed in practice: Buffered, Streaming */ }

#non_exhaustive
pub(all) enum ResponseFailure {             // an expected failure: a value, not an effect
  UnexpectedStatus(@mttp.ResponseHead, body~ : Bytes)                  // body: at most 1 MiB of diagnostic bytes
  Deserialization(@mttp.ResponseHead, message~ : String, body~ : Bytes)
} derive(Eq, Debug)
pub fn ResponseFailure::head(self : ResponseFailure) -> @mttp.ResponseHead
pub fn status_of(f : ResponseFailure) -> Int?
pub(all) suberror InvalidRequest { InvalidRequest(message~ : String) } derive(Debug)   // raised by encoders, never sent

// how to read a response
pub struct ResponsePlan[T, M] { /* private */ }
pub fn as_bytes() -> ResponsePlan[Result[Bytes, ResponseFailure], Buffered]     // as_string, as_json_value, as_form(max_pairs?), ignore_body
pub fn[T : FromJson] as_json() -> ResponsePlan[Result[T, ResponseFailure], Buffered]
pub fn[T] as_stream(f : async (@mttp.ResponseHead, &@mttp.BodyStream) -> T) -> ResponsePlan[Result[T, ResponseFailure], Streaming]
pub fn as_sse(f : async (@sse.SseEvent) -> Unit, max_event_bytes? : Int, stop? : (@sse.SseEvent) -> Bool)
  -> ResponsePlan[Result[Unit, ResponseFailure], Streaming]                       // as_lines(f, max_line_bytes? = 1 MiB)
pub fn[T, M : ResponseMode] from_head(choose : (@mttp.ResponseHead) -> ResponsePlan[T, M]) -> ResponsePlan[T, M]
pub fn[A, B] as_both(a : ResponsePlan[A, Buffered], b : ResponsePlan[B, Buffered]) -> ResponsePlan[(A, B), Buffered]
pub fn[T] ResponsePlan::new(f : (@mttp.ResponseHead, Bytes) -> T raise) -> ResponsePlan[T, Buffered]
pub fn[T] ResponsePlan::stream(f : async (@mttp.ResponseHead, &@mttp.BodyStream) -> T) -> ResponsePlan[Result[T, ResponseFailure], Streaming]
pub fn[T] ResponsePlan::reject() -> ResponsePlan[Result[T, ResponseFailure], Buffered]
// any_status, map, map_ok, map_with_head; as_streaming (Buffered -> Streaming widening only)

// a request plus how to read its response
pub struct RequestPlan[T, M] { /* private: raw request, plan, per-request overrides */ }
pub fn request(raw : @mttp.Request) -> RequestPlan[Result[String, ResponseFailure], Buffered]   // get(url), post(url)
pub fn[T, M] RequestPlan::new(raw : @mttp.Request, plan : ResponsePlan[T, M]) -> RequestPlan[T, M]
pub fn[T, U, M, N] RequestPlan::response(self : RequestPlan[T, M], plan : ResponsePlan[U, N]) -> RequestPlan[U, N]
// header, bearer, body_bytes, body_json, body_fn (built per attempt, after admission), attribute,
// timeout_ms, max_body_bytes, read_idle_ms; follow_redirects(Bool), max_redirects(Int) set the redirect attribute
pub async fn[T, M : ResponseMode] RequestPlan::send(self : RequestPlan[T, M], client : Client,
  decide_retry? : (AttemptResult[T], RetryContext) -> @retry.Decision) -> Reply[T]
pub fn[T] RequestPlan::to_curl(self : RequestPlan[T, Buffered], sensitive_headers? : Array[String], include_body? : Bool) -> String
pub type ClientRequest[T] = RequestPlan[T, Buffered]
pub type ResponseAs[T] = ResponsePlan[T, Buffered]

pub(all) struct Reply[T] { status : Int; headers : @mttp.Headers; body : T; request : @mttp.RequestHead; attributes : @mttp.Attributes }

// Backend + defaults + policy: the only sending path
pub fn Client::new(
  backend : &@mttp.Backend, clock : &@rt.Clock,
  base_url? : String,             // prefix join (join_url), never RFC 3986 resolve
  headers? : @mttp.Headers,       // defaults; a header the request sets itself wins
  timeout_ms? : Int,              // (new form) attempt deadline, passed as SendOptions.timeout_ms
  max_body_bytes? : Int,          // (new form) decoded limit for Buffered plans, 64 MiB; also the wire cap sent as Exchange(max_bytes)
  read_idle_ms? : Int,            // (new form) per-read deadline for Streaming plans, sent as Stream(idle_ms)
  timer? : &@rt.Timer,            // required when total_ms is set
  retry? : RetryPolicy,           // default: none
  limiter? : &RateLimiter,
  total_ms? : Int,                // whole-call deadline
  observer? : (Attempt) -> Unit,
  random? : () -> Double,
) -> Client
pub async fn[T, M : ResponseMode] Client::send(self : Client, r : RequestPlan[T, M],
  decide_retry? : (AttemptResult[T], RetryContext) -> @retry.Decision) -> Reply[T]
pub fn Client::close(self : Client) -> Unit

// retry: policy data plus an optional typed decision
pub(all) enum AttemptResult[T] { Buffered(Reply[T]); StreamReady(@mttp.ResponseHead); TransportFailure(@mttp.TransportError) }
pub(all) struct RetryContext { request : @mttp.RequestHead; idempotent : Bool; bucket : String; attempt : Int; random : Double
  now_unix_ms : Int64; remaining_ms : Int64?; replayable : Bool; default_decision : @retry.Decision }
pub fn RetryContext::capture(request : @mttp.Request, ..) -> RetryContext      // reads live facts once
pub fn RetryContext::new(head : @mttp.RequestHead, idempotent~ : Bool, replayable~ : Bool, ..) -> RetryContext
pub(all) struct RetryPolicy { rule : @retry.RetryRule } derive(Eq, Debug)
pub fn RetryPolicy::conservative() -> RetryPolicy   // none, default, from_rule, with_max_retries, allow_non_idempotent
pub(open) trait RateLimiter {
  async fn acquire(Self, String, global_exempt~ : Bool) -> Admission
  async fn release(Self, Admission, status~ : Int, headers~ : @mttp.Headers) -> Unit
}
pub struct Admission { /* opaque bucket and limiter-issued sequence */ }
pub fn Admission::new(bucket : String, sequence~ : Int64) -> Admission
pub fn Admission::bucket(Self) -> String
pub fn Admission::sequence(Self) -> Int64
// Return each Admission only to its issuer. A second release is ignored;
// implementations track outstanding identities within their resource bound.
pub(all) struct Attempt { request : @mttp.RequestHead; attributes : @mttp.Attributes; bucket : String; attempt : Int
  status : Int; headers : @mttp.Headers; duration_ms : Int64; error : Error?; decision : @retry.Decision? }
pub let rate_limit_bucket : @mttp.AttributeKey[String]     // global_exempt, operation_id
pub fn[T, E] Paginator::with_cursor(f : async (String?) -> Result[Page[T], E]) -> Paginator[T, E]   // new, next_page, each, collect(max~)

// Backend wrappers
pub fn from_fn(f : async (@mttp.Request, @mttp.SendOptions) -> @mttp.Response raise @mttp.TransportError, on_close? : () -> Unit) -> &@mttp.Backend
pub(all) struct RedirectConfig { max_redirects : Int; allow_downgrade : Bool; credential_headers : Array[String] }  // (new) default 10, false, the credential set
pub let redirect_limit : @mttp.AttributeKey[Int]          // (new) per-request override; 0 = do not follow
pub fn FollowRedirects::new(inner : &@mttp.Backend, config? : RedirectConfig, on_redirect? : (RedirectHop) -> Unit) -> FollowRedirects
pub let redirect_history : @mttp.AttributeKey[Array[RedirectHop]]
// gaato/mttp/client/cookies
pub fn Cookies::new(inner : &@mttp.Backend, jar : @cookie.CookieJar) -> Cookies
```

**Response modes.** Requests and response descriptions carry their mode in the type. A Buffered plan is read inside the attempt, so a reader's `Err` or a rejected status reaches the decision; a Streaming plan's callback starts only after the attempt's release and observation, and its result or exception is never retried. `from_head` lets the head choose a branch, but the *mode* only describes what may happen; the chosen branch decides the actual lifetime, and metadata selection never turns a stream callback into a retryable buffered operation. `as_both` accepts only Buffered plans; a Buffered plan may widen to Streaming explicitly (`as_streaming`), never the reverse.

**Expected failures are values.** Built-in readers return `Result[_, ResponseFailure]`: a rejected status is `UnexpectedStatus` with the real head and at most 1 MiB of body, an undecodable body is `Deserialization`. `TransportError` stays raised, and cancellation and unknown user exceptions keep their identity. SDKs expose expected API, decode and validation failures as values and propagate TransportError separately.

**Mapping a plan to SendOptions.** The Client sends `SendOptions { timeout_ms, body }` with `Exchange(max_bytes = max_body_bytes)` for a Buffered plan and `Stream(idle_ms = read_idle_ms)` for a Streaming one; per-request overrides win field by field. The engine bounds wire bytes with that cap; the Client's reader bounds decoded bytes with the same number. A coded body whose wire form is larger than its decoded form at the limit is refused at the wire; the cap is a safety bound, not a quota. A `from_head` plan is sent as `Stream(idle_ms)`, because the branch is unknown until the head arrives. When the head selects a Buffered branch, the Client reads that body under the remainder of the attempt's `timeout_ms` (its own Timer, started with the attempt) and bounds decoded bytes with `max_body_bytes`; wire bytes stay bounded by the engine ceiling `ClientConfig.max_body_bytes`, which applies in both modes. The selected branch therefore keeps the deadline and cap it would have had as a plain Buffered plan, apart from the per-request wire cap.

**The Client loop.** sdk-runtime's hardened loop, generalised.

1. **Prepare once.** `url = join_url(base_url, raw.url)`; defaults merge under the request's own headers; the bucket is the `rate_limit_bucket` attribute, else `"default"`; `global_exempt` from its attribute. The request is replayable if `body_fn` is set or the body is replayable.
2. **Validate before admission.** A total deadline without a Timer, or a non-positive limit, fails before admission or body acquisition. A non-positive attempt `timeout_ms` fails that attempt at once with `Timeout(ms)`; the backend never sees a value ≤ 0.
3. **Total deadline.** `total_ms` covers admission, body preparation, attempts, backoff and stream consumption. It requires a Timer. Expiry requests cancellation; required cleanup may finish after the deadline. No attempt and no consumer starts after expiry.
4. **Each attempt.** `acquire`, then the body from `body_fn`, then `send`. The head is captured as soon as it arrives.
5. **Head rejected:** read at most 1 MiB, close the body, produce `Err(UnexpectedStatus)` inside the attempt, so the decision sees error statuses even for Streaming plans.
6. **Exactly one `release` per completed `acquire`, with that acquire's `Admission`.** It uses the head's status and headers whenever a head arrived, even if reading failed. A cancelled admission wait has no release. Duplicate releases are ignored. Release must complete or roll back safely when cancelled: synchronous close and compensation run during unwind, and only necessary asynchronous cleanup is shielded.
7. **Release errors.** A release failure after the exchange produced a value (including an `Err` value) reaches the caller and closes any held body. It never replaces an already raised error or a cancellation.
8. **Observer.** Gets one `Attempt` after release is attempted, with the actual status and head, any raised error and the decision. Logical calls, policy attempts, redirects and stale-connection repairs are distinct and never conflated.
9. **Decision.** `RetryPolicy` is data; `decide_retry` is an optional typed function over `AttemptResult` that also receives the policy's `default_decision`. The executor enforces the retry count, the replay source and the remaining budget whatever the function says: without a body factory, a stream request is never resent; a `Wait` past the budget becomes `Stop(Budget)`. `Wait(ms)` sleeps on the injected clock.
10. **Idempotency** comes from the method or the explicit `replay_safe` attribute. An Idempotency-Key header alone does not prove that a service deduplicates. Vendor presets (the old `stainless`) belong to the SDK that needs them; the core keeps `none`, `default` and `conservative`.
11. **Close.** Records shared closure before closing the backend idempotently. A planned retry checks closure before backoff and after waking, before another acquire/attempt, and returns the last outcome as `Stop` would. An existing `Clock.sleep` is not interrupted; later sends fail with `Closed` in phase Pool before admission. The completed attempt still releases its Admission.

**Redirects.** FollowRedirects is configured once (`RedirectConfig`) and overridden per request through the `redirect_limit` attribute (set by `RequestPlan::follow_redirects` and `max_redirects`). It closes intermediate bodies unread, records `redirect_history`, and composes with Cookies. Retry sits above redirects: a 503 on hop 2 re-sends hop 1.

**Port note.** `client/retry` and `client/ratelimit` keep their PR #2 form; the only change is `@model`/`@clock` → `@http`/`@rt`. RetryRule consumes a RequestHead plus explicit idempotency and replayability (CONTRACT, decision snapshots).

### 4.5 h1 codec and the connection engines

PR #2 measured the reasons for owning the codec (F36–F39): stock parsers read heads and chunk lines without a bound, ingest headers quadratically, serve a smuggled request after CL+TE and merge duplicate headers. The same gaps remain in core/async/http on 0.10.20 (F65). gaato/mttp therefore owns the codec, and both engines parse with it.

```moonbit
// gaato/mttp/h1 — all 4 targets; imports the root only
pub(all) struct Limits { max_head_bytes : Int; max_chunk_line_bytes : Int; max_trailer_bytes : Int
  max_headers : Int } derive(Eq, Debug)       // default: 16 KiB incl. CRLF, 4 KiB, 16 KiB, 100 fields (also per trailer block)
#non_exhaustive
pub(all) enum ParseKind { HeadTooLarge; Malformed; Smuggling; Unsupported } derive(Eq, Debug)
pub(all) suberror ParseError { ParseError(kind~ : ParseKind, detail~ : String) } derive(Debug)
#non_exhaustive
pub(all) enum Version { Http10; Http11 } derive(Eq, Debug)
pub fn HeadDecoder::new(max? : Int) -> HeadDecoder                          // feed -> HeadResult, finish; linear, sticky errors
pub fn scan_head(buf : BytesView, max~ : Int) -> Int? raise ParseError       // stateless alternative
pub struct ParsedRequest { meth : @mttp.Method; target : String; version : Version; headers : @mttp.Headers }   // (new) read-only
pub struct ParsedResponse { version : Version; status : Int; headers : @mttp.Headers }                         // (new) read-only
pub fn parse_request_head(head : BytesView, limits? : Limits) -> ParsedRequest raise ParseError    // (new form; was a 4-tuple)
pub fn parse_response_head(head : BytesView, limits? : Limits) -> ParsedResponse raise ParseError  // (new form; was a 3-tuple)
#non_exhaustive
pub(all) enum Framing { NoBody; Length(Int64); Chunked; UntilClose } derive(Eq, Debug)
pub fn request_framing(headers : @mttp.Headers) -> Framing raise ParseError  // CL+TE -> Smuggling; duplicate (even identical) or invalid CL -> Malformed
pub fn response_framing(headers : @mttp.Headers, status~ : Int, meth? : @mttp.Method) -> Framing raise ParseError
pub fn ChunkedDecoder::new(limits : Limits) -> ChunkedDecoder                // feed -> Decoded, finish; payload not buffered
pub struct Decoded { chunks : Array[Bytes]; done : Bool; trailers : @mttp.Headers; consumed : Int }   // read-only
pub fn write_request_head(meth : @mttp.Method, target : String, headers : @mttp.Headers, framing : Framing, version : Version) -> Bytes raise ParseError
pub fn write_response_head(status : Int, headers : @mttp.Headers, framing : Framing, version : Version) -> Bytes raise ParseError
pub fn encode_chunk(b : Bytes) -> Bytes
```

The parse results become named, read-only structs because a stable layer cannot grow a tuple without breaking every match; a read-only struct can gain fields. Wire writers raise rather than emit unsafe bytes, and they replace CL/TE from the supplied framing.

Codec rules (RFC 9112, stricter where noted):

| Case | Behaviour |
|---|---|
| `HeadTooLarge` | 431 and close |
| `Malformed` (incl. a missing `Host` on HTTP/1.1; obs-fold, controls, whitespace before a colon; any duplicate Content-Length) | 400 and close |
| `Smuggling` (CL and TE together) | 400 and close, in **both** engines through the same `request_framing`/`response_framing` |
| `Unsupported` (any transfer coding other than a single `chunked`) | 501 |
| HTTP/1.0 request | Keep-alive only when asked for; framed by `Length` or `UntilClose`, never `Chunked` |
| `Expect: 100-continue` | `100 Continue` only after the route, the security inputs and the head inputs passed; otherwise the final status and close, without reading the body |
| Successful CONNECT | `NoBody` describes the message only; the engine hands the remaining bytes to the tunnel |

```moonbit
// gaato/mttp/h1client
pub(all) struct ClientConfig {        // (new) collects H1Backend::new's optional parameters; build with default() + record update
  proxy : String?; lookup : ((String) -> String?)?      // proxy env lookup is captured at construction through the callback
  connect_timeout_ms : Int?; write_timeout_ms : Int?; read_timeout_ms : Int?; pool_timeout_ms : Int?
  max_connections : Int?; max_connections_per_origin : Int?          // unset = no cap; caps below 1 count as 1
  max_idle_connections : Int; max_idle_per_origin : Int; idle_max_ms : Int   // 256, 4, 10 000
  max_body_bytes : Int?               // hard wire ceiling; effective cap = min(ceiling, Exchange.max_bytes)
  head_limits : @h1.Limits
}
pub fn ClientConfig::default() -> ClientConfig
pub fn Client::new(dialer~ : &@rt.Dialer, clock~ : &@rt.Clock, timer~ : &@rt.Timer,
  coordination~ : &@rt.Coordination, config~ : ClientConfig) -> Client
pub impl @mttp.Backend for Client                                    // idle_connections
// gaato/mttp/h1server
pub(all) struct ServerLimits { max_body_bytes : Int; header_timeout_ms : Int; body_timeout_ms : Int; max_header_bytes : Int
  max_connections : Int; drain_max_bytes : Int; handler_timeout_ms : Int?; drain_ms : Int }
pub fn ServerLimits::default() -> ServerLimits     // 1 MiB, 5000, 5000, 16 KiB, 256, 64 KiB, None, 10 000; validate
pub(all) suberror ServerConfigError { InvalidMaxBodyBytes(value~ : Int); InvalidBodyTimeoutMs(value~ : Int)
  InvalidHeaderTimeoutMs(value~ : Int); InvalidMaxConnections(value~ : Int); InvalidMaxHeaderBytes(value~ : Int)
  InvalidDrainMaxBytes(value~ : Int); InvalidHandlerTimeoutMs(value~ : Int); InvalidDrainMs(value~ : Int) } derive(Debug)
pub async fn serve_conn(conn : &@rt.Conn, handler : @mttp.Handler, clock~ : &@rt.Clock, timer~ : &@rt.Timer,
  coordination~ : &@rt.Coordination, scheme~ : String, limits? : ServerLimits, peer? : String, authority? : String,
  on_error? : (@mttp.TransportError) -> Unit, stopping? : () -> Bool, background? : (async () -> Unit) -> Unit) -> Unit
```

Engine rules:

- **Client engine.** Pool, slots, wire, body and deadlines run over the ports; the Buffered/Streaming choice comes from `BodyTiming`. It reads response heads, chunk lines, trailers and a proxy's CONNECT answer within `head_limits`, so the old "unbounded client head" gap (F63, risk 20) is closed for every target that uses the engine. A response that arrives early during an upload cancels the unfinished upload and excludes the socket from reuse; informational responses keep upload progress. The outgoing stream's first read happens before the head is written, so a stream that fails or lies about being empty sends nothing.
- **Stale-connection repair.** A failure on a reused idle connection before any response byte is resent once on a fresh connection only if the body is replayable *and* the request is resend-safe (`@mttp.is_idempotent`: an idempotent method or the `replay_safe` attribute). Receiving no response bytes does not prove the request was unprocessed, so replayability alone never licenses a resend; otherwise the failure surfaces with its phase. This repair is not a policy attempt and is reported separately (§4.4 rule 8).
- **Server engine.** `serve_conn` owns the accepted connection and closes it on every exit. The handler gets an absolute `Request.url` from `scheme~` and the `Host` header. A supplied background scheduler owns detached work; without one, no `background` attribute is advertised. A client disconnect cancels the handler. Failures reported through `on_error` are `TransportError` values; runtime error identities never escape. Compression is not an engine concern: wrap the handler with `@codings.compress` (§4.11).
- **Control.** Admission, pool metadata, peer EOF/failure and listener lifecycle are transitions of `internal/control` (§5.11).
### 4.6 schema

```moonbit
pub(all) struct Schema { name : String?; json : Json; defs : Map[String, Json] } derive(Eq, Debug)  // defs: every named schema reachable
pub fn Schema::of(json : Json) -> Schema
pub fn Schema::reference(self : Schema, into : Map[String, Json]) -> Json   // "$ref" for a named schema (merging defs), the body otherwise
pub(all) struct Issue { path : String; code : String; message : String } derive(Eq, Debug, ToJson)
// (new form) wf3/rev compiled DecodeFailure with these cases as its own constructors; the kind form lets it grow (§5.6)
#non_exhaustive
pub(all) enum DecodeKind { Missing; Multiple(Int); Malformed; Invalid(Array[Issue])
  Mismatch(expected~ : String, actual~ : String); TooLarge(limit~ : Int); UnsupportedMediaType(String) } derive(Debug)
pub(all) suberror DecodeFailure { DecodeFailure(kind~ : DecodeKind, message~ : String) } derive(Debug)
pub fn DecodeFailure::message(self : DecodeFailure) -> String

pub fn minimum(n : Int) -> Validator[Int]          // max_length; (new) maximum, min_length, one_of_values, custom(f, keywords?)
pub(all) suberror UnsupportedPattern { UnsupportedPattern(String) } derive(Debug)   // (new)
pub fn pattern(ecma : String) -> Validator[String] raise UnsupportedPattern       // (new) [needs-prototype] see below
pub fn[T] TextCodec::new(decode : (String) -> T raise DecodeFailure, encode : (T) -> String, schema : Schema) -> TextCodec[T]
pub let int : TextCodec[Int]                        // string; (moved/new) int64, double, bool, enum_of
pub fn[T] TextCodec::validate(self : TextCodec[T], v : Validator[T]) -> TextCodec[T]
pub fn[T, U] TextCodec::map(self : TextCodec[T], to : (T) -> U raise DecodeFailure, from : (U) -> T) -> TextCodec[U]

pub let jint : JsonCodec[Int]                       // jstring, jvalue (Json passthrough); (new) jint64, jdouble, jbool, option, map_of
pub fn[T] array(c : JsonCodec[T]) -> JsonCodec[Array[T]]   // collects every issue with its index path
pub fn[T, A] field(name : String, codec : JsonCodec[A], get : (T) -> A) -> Field[T, A]
pub fn[T, A, B] object2(name : String, a : Field[T, A], b : Field[T, B], make : (A, B) -> T) -> JsonCodec[T]  // object1..object8 generated; more on demand
pub fn[T] recursive(name : String, body : (JsonCodec[T]) -> JsonCodec[T]) -> JsonCodec[T]  // tapir SRef: $ref to itself
pub fn[T : FromJson + ToJson] JsonCodec::derived(schema : Schema) -> JsonCodec[T]
pub(open) trait JsonSchema { json_schema(Self?) -> Schema }
pub fn[T : FromJson + ToJson + JsonSchema] json() -> JsonCodec[T]
// (new) discriminated and untagged unions; derive(ToJson) cannot emit {"type": ..., fields} (F21)
pub fn[T, A] case_(tag : String, codec : JsonCodec[A], project : (T) -> A?, inject : (A) -> T) -> Case[T]
pub fn[T] tagged(name : String, discriminator : String, cases : Array[Case[T]]) -> JsonCodec[T]   // oneOf + discriminator.mapping
pub fn string_enum(name : String, values : Array[String]) -> JsonCodec[String]   // any_of(..) for untagged unions
pub fn[T] presence(codec : JsonCodec[T]) -> JsonCodec[@jsonkit.Presence[T]]       // (new) open_string(known); the jsonkit edge

pub fn[T] JsonCodec::body(self : JsonCodec[T]) -> BodyCodec[T]
pub let text_body : BodyCodec[String]               // raw_bytes; (new) form_body(max_pairs?)
```

- **Named children are `$ref`s.** Combinators embed a named child through `reference` and carry its definition in `defs`, so nested types keep their names and recursive types are possible. In `wf3/rev`, Team refers to User by `$ref` and Tree's `children.items` refers to Tree (SC-01).
- **Patterns are ECMA-262 source.** `@string.Regex` uses lexmatch syntax and rejects real spec patterns, for example `^[a-zA-Z0-9_-]{1,64}$` and `\d` (F22). `pattern(ecma)` translates the common subset (`\d \w \s` to POSIX classes, an edge `-` to `\-`). It refuses anything else when the validator is built, and the documentation emits the original ECMA string. tools/gen routes spec patterns through the same translator. The translator **[needs-prototype]**; a translation corpus goes to `mttp/conformance`.
- **Three JSON mechanisms, one role each.**
  - `as_json` (derive FromJson) is for client readers.
  - `JsonCodec` is for endpoints: it collects every issue and its schema cannot drift.
  - `jsonkit` is for generated SDK models.

### 4.7 endpoint

```moonbit
// inputs: untyped atoms (routing, docs, ranking of failures) built together with typed staged closures
#non_exhaustive
pub(all) enum AuthScheme { Bearer(format~ : String?); Basic; ApiKeyHeader(String); ApiKeyQuery(String); ApiKeyCookie(String); Signature(String) }   // OAuth2, OpenIdConnect later
#non_exhaustive
pub(all) enum Location { Path; Query; Header; Cookie; Auth(scheme~ : AuthScheme, scheme_name~ : String); Body(media_type~ : String, streamed~ : Bool); RawBody; Derived }   // Derived: attribute/unit inputs, read from no part of the request
pub struct Atom { location : Location; name : String; schema : @schema.Schema; required : Bool; description : String? }  // (new: read-only; pub(all) in wf3/rev) docs fields will grow (SC-13)
pub fn Atom::new(location : Location, name : String, schema : @schema.Schema, required? : Bool, description? : String) -> Atom  // (new)
pub struct Head { request : @mttp.Request; captures : Map[String, String]; query : Array[(String, String)] }   // what an input sees before the body
pub struct RequestSink { /* private */ }                                    // (new) opaque; wf3/rev had read-only `mut` fields (E4094 outside endpoint)
pub fn RequestSink::set_header(self : RequestSink, name : String, value : String) -> Unit    // (new)
pub fn RequestSink::add_query(self : RequestSink, name : String, value : String) -> Unit     // (new)
pub fn RequestSink::set_capture(self : RequestSink, name : String, value : String) -> Unit   // (new)
pub fn RequestSink::set_body(self : RequestSink, body : @mttp.Body) -> Unit                 // (new)
pub(all) enum BodyValue { NoBody; Buffered(Bytes); Streamed(&@mttp.BodyStream) }
pub struct Staged[T] { /* private */ }
pub fn[T] Staged::ready(v : T) -> Staged[T]                                                     // (new) head-only input
pub fn[T] Staged::after_body(finish : (BodyValue) -> T raise InputErrors) -> Staged[T]          // (new) needs the body
pub(all) struct InputFailure { atom : Atom; failure : @schema.DecodeFailure }
pub(all) suberror InputErrors { InputErrors(Array[InputFailure]) }
pub fn[T] Input::new(atoms : Array[Atom], decode : (Head) -> Staged[T] raise InputErrors, encode : (T, RequestSink) -> Unit) -> Input[T]

pub fn unit() -> Input[Unit]
pub fn[T] path(name : String, codec : @schema.TextCodec[T]) -> Input[T]    // query, header; (new) query_list, cookie
pub fn bearer(scheme_name? : String) -> Input[String]                     // missing -> 401 + WWW-Authenticate; (new) basic, api_key_*
pub fn signature_header(name : String) -> Input[String]                   // missing -> 401; documented as a required header
pub fn raw_body() -> Input[Bytes]                                         // in a security input: buffered (endpoint limit) before authenticate
pub fn[T] body(codec : @schema.BodyCodec[T]) -> Input[T]                  // 415 media type, 413 size, 400 issues
pub fn[T] attribute(key : @mttp.AttributeKey[T]) -> Input[T?]            // server-only: no docs, no-op on encode (SC-07)
// (new) stream_body(media), query_params(), headers(), paths(name) for a {name...} capture, client_ip(trust_forwarded~)
pub fn[T] Input::optional(self : Input[T]) -> Input[T?]
pub fn[T, U] Input::map(self : Input[T], to : (T) -> U raise @schema.DecodeFailure, from : (U) -> T) -> Input[U]
pub fn[A, B, T] Input::map2(a : Input[A], b : Input[B], to : (A, B) -> T, from : (T) -> (A, B)) -> Input[T]  // map3..map8 generated; nest pairs beyond 8
pub fn[A, B] pair(a : Input[A], b : Input[B]) -> Input[(A, B)]

// outputs and declared errors: a variant = (status, media type, headers, codec); an Out carries a response mode
pub fn[T] json_variant(status : Int, codec : @schema.BodyCodec[T], description? : String) -> Variant[T]
pub fn empty_variant(status : Int, description? : String) -> Variant[Unit]
pub fn[A, T] Variant::contramap(self : Variant[A], project : (T) -> A?, inject : (A) -> T) -> Variant[T]
pub fn[T, H] Variant::and_header(self : Variant[T], name : String, codec : @schema.TextCodec[H]) -> Variant[(T, H)]   // fixed_header, and_status
pub fn[T] one_of(variants : Array[Variant[T]]) -> Out[T, @client.Buffered]
pub fn[T] json_out(codec : @schema.BodyCodec[T], status? : Int) -> Out[T, @client.Buffered]       // no_content, text_out, bytes_out
pub fn stream_body_out(status? : Int) -> Out[(String?, @mttp.Body), @client.Buffered]              // content type computed per response
pub fn[T] sse_out(codec : @schema.JsonCodec[T], to_event? : (T) -> @sse.SseEvent) -> Out[EventStream[T], @client.Streaming]
pub fn[T, H, M] Out::and_header(self : Out[T, M], name : String, codec : @schema.TextCodec[H]) -> Out[(T, H), M]   // and_status, set_cookie
pub fn[T] EventStream::from_pull(next : async () -> T?, close : () -> Unit) -> EventStream[T]       // from_array, each, close
pub(all) struct NoError derive(Eq, Debug)

// endpoints: builders never raise, so endpoints are top-level `pub let`s; the fifth parameter is the response mode
pub let endpoint : Endpoint[Unit, Unit, NoError, Unit, @client.Buffered]
pub fn[S, I, E, O, M] Endpoint::path(self : Endpoint[S, I, E, O, M], template : String) -> Endpoint[S, I, E, O, M]   // get, post, delete, with_method
pub fn[I, E, O, S2, M] Endpoint::security(self : Endpoint[Unit, I, E, O, M], s : Input[S2]) -> Endpoint[S2, I, E, O, M]   // set-once
pub fn[S, E, O, I2, M] Endpoint::input(self : Endpoint[S, Unit, E, O, M], i : Input[I2]) -> Endpoint[S, I2, E, O, M]
pub fn[S, I, O, E2, M] Endpoint::errors(self : Endpoint[S, I, NoError, O, M], e : Out[E2, @client.Buffered]) -> Endpoint[S, I, E2, O, M]
pub fn[S, I, E, O2, M, N] Endpoint::output(self : Endpoint[S, I, E, Unit, M], o : Out[O2, N]) -> Endpoint[S, I, E, O2, N]
// operation_id, summary, tag, max_body_bytes, rate_limit_bucket(f : (@mttp.Request) -> String), doc() -> EndpointDoc

// the one definition checker (Router::new, to_openapi and testkit.verify all call it)
pub(all) struct DefinitionProblem { template : String; message : String; fatal : Bool } derive(Eq, Debug)
pub fn check_definitions(docs : Array[EndpointDoc]) -> Array[DefinitionProblem]
pub(all) suberror DefinitionError { DefinitionError(Array[DefinitionProblem]) } derive(Debug)

// server interpreter (one endpoint; the router picks it). Declared errors are values: no Error bound on E
#non_exhaustive
pub(all) enum FailureStage { Security; Head; Body } derive(Eq, Debug)
pub(all) struct FailureContext { request : @mttp.Request; endpoint : EndpointDoc; failures : Array[InputFailure]; stage : FailureStage }
pub(all) struct DispatchContext { max_body_bytes : Int; max_issues : Int
  decode_failure : (FailureContext) -> @mttp.Response; unhandled : (@mttp.Request, Error) -> @mttp.Response }
pub let route_template : @mttp.AttributeKey[String]     // set on every dispatched response
pub fn[S, I, E, O, P, M] Endpoint::serve(self : Endpoint[S, I, E, O, M], authenticate : async (S) -> Result[P, E],
  handle : async (P, I) -> Result[O, E]) -> ServerEndpoint
pub fn[I, E, O, M] Endpoint::serve_public(self : Endpoint[Unit, I, E, O, M], handle : async (I) -> Result[O, E]) -> ServerEndpoint
pub async fn ServerEndpoint::dispatch(self : ServerEndpoint, req : @mttp.Request, params : Map[String, String], ctx : DispatchContext) -> @mttp.Response noraise

// client interpreter: relative targets, joined onto Client's base_url
pub fn[S, I, E, O] Endpoint::request(self : Endpoint[S, I, E, O, @client.Buffered], security : S, input : I)
  -> @client.RequestPlan[Result[Result[O, E], @client.ResponseFailure], @client.Buffered] raise @client.InvalidRequest
pub fn[S, I, E, O, R, M] Endpoint::stream_request(self : Endpoint[S, I, E, O, M], security : S, input : I, use_ : async (O) -> R)
  -> @client.RequestPlan[Result[Result[R, E], @client.ResponseFailure], @client.Streaming] raise @client.InvalidRequest
pub async fn[S, I, E, O] Endpoint::call(self : Endpoint[S, I, E, O, @client.Buffered], client : @client.Client, security : S, input : I)
  -> Result[Result[O, E], @client.ResponseFailure]
pub async fn[S, I, E, O, R, M] Endpoint::call_with(self : Endpoint[S, I, E, O, M], client : @client.Client, security : S, input : I,
  use_ : async (O) -> R) -> Result[Result[R, E], @client.ResponseFailure]
```

**Custom inputs.** `Input::new` is public so that third-party inputs (client IP, custom auth) can be written outside the package. In `wf3/rev` it could not be used from outside: `Staged[T]` had no public constructor (E4015), and `RequestSink`'s `mut` fields are read-only outside the package (E4094). `Staged::ready`/`after_body` and the `RequestSink` setters above fix both. P-01 stays "Input::new usable outside endpoint: not yet verified" until a cross-package test passes.

**Result contract.** The client result is `Result[Result[O, E], ResponseFailure]`: the outer `Err` is a response the endpoint did not declare (or could not decode), the inner `Err` a declared application error. Server `authenticate` and handlers return `Result` too. These wrappers never change the wire JSON. A Streaming endpoint rejects a Buffered request (`Endpoint::request` takes only Buffered endpoints), and `as_both` rejects streaming readers; both are compile-time refusals checked by an external-package type probe (`scripts/type_contracts.mbtx`).

**Empty versus absent bodies.** Framing decides whether a request has no body (`Body::Empty`) or a stream; the endpoint checks `Empty` first, before reading, so an absent body is never confused with an empty one (the regression from PR #2's review, `endpoint/input.mbt`).

Client interpreter rules (verified unless marked):

- **Variant selection by (status, media type).** An empty variant matches only a response without a content type. A framework `application/problem+json` 404 is never decoded as a declared `application/json` 404; it surfaces as `Err(UnexpectedStatus(404))` (I-02).
- **Same-status variants are tried in declaration order.** `Deserialization` results only if every candidate fails (SC-04).
- **Inside the attempt.** Output and declared-error variants are matched and decoded inside the attempt, so `call_with` (streaming) sees the same retry decisions on 503 as `call` (I-03). The streaming callback itself runs after the attempt and is never replayed (§4.4).
- **Request attributes.** The encoded request carries `operation_id`. It sets `rate_limit_bucket` only when the endpoint declares `rate_limit_bucket(f)`; otherwise the Client uses `"default"`. GitHub and discord bucket by method, URL and route, never by operation id.
- **Marking a call.** `@api.op.request(s, i).attribute(@mttp.replay_safe, true)`.
- **Sync half stays internal.** `encode_request`/`decode_response` stay internal until a consumer (browser, Rabbita) needs them.

Known limits, documented rather than changed:

- **Set-once leaks while a slot's type is `Unit`.** `.output(no_content()).output(json_out(..))` compiles (I-07).
- **A base endpoint cannot share a path capture.** Each endpoint re-declares `{org}` in its own input (I-08).
- **Unqualified constructors work only inside the defining package** (I-06). Declared errors are ordinary values now, so this affects only pattern matches on them: qualify as `@api.NotFound`.

Usage (sketch in the Result form; PR #2's `endpoint`, `router` and conformance tests hold compiled equivalents):

```moonbit
// definition package: imports @http, schema and endpoint only; checks on wasm-gc
pub(all) enum ApiError { NotFound(Int); Forbidden; NoTeam(String) } derive(Eq, Debug)
let api_errors : @endpoint.Out[ApiError, @client.Buffered] = @endpoint.one_of([
  @endpoint.json_variant(404, @schema.jint.body()).contramap(e => match e { NotFound(id) => Some(id); _ => None }, id => NotFound(id)),
  @endpoint.json_variant(404, @schema.jstring.body()).contramap(e => match e { NoTeam(n) => Some(n); _ => None }, n => NoTeam(n)),
  @endpoint.empty_variant(403).contramap(e => match e { Forbidden => Some(()); _ => None }, _ => Forbidden),
])
pub let get_user : @endpoint.Endpoint[String, Int, ApiError, User, @client.Buffered] = @endpoint.endpoint
  .path("/api/v1").security(@endpoint.bearer()).errors(api_errors)
  .get("/users/{id}")
  .input(@endpoint.path("id", @schema.int.validate(@schema.minimum(1))))
  .output(@endpoint.json_out(user_json.body()))
  .operation_id("getUser")

// server package
let auth : async (String) -> Result[String, @api.ApiError] = token => if token == "secret" { Ok("admin") } else { Err(@api.Forbidden) }
let router = @router.Router::new([
  @api.get_user.serve(auth, (_who, id) => match store.get(id) { Some(u) => Ok(u); None => Err(@api.NotFound(id)) }),
])
// client: any Backend, including the Router itself in tests
let client = @client.Client::new(router, clock, base_url="http://in-process")
match @api.get_user.call(client, "secret", 1) {
  Ok(Ok(user)) => ...
  Ok(Err(@api.NotFound(_))) => ...              // declared
  Ok(Err(other)) => ...
  Err(failure) => ...                            // undeclared status or undecodable body
}
```

### 4.8 router

```moonbit
pub using @endpoint {type FailureContext}
pub type Middleware = async (@mttp.Request, async (@mttp.Request) -> @mttp.Response noraise) -> @mttp.Response noraise
pub(all) struct ServerOptions {
  max_body_bytes : Int                                                   // default per-endpoint limit (1 MiB); Endpoint::max_body_bytes overrides
  max_issues : Int                                                       // 100
  decode_failure : (@endpoint.FailureContext) -> @mttp.Response?       // None = default table
  reject : (@mttp.Request, Array[@mttp.Method]) -> @mttp.Response    // 404 / 405 + Allow
  on_unhandled : (@mttp.Request, Error) -> @mttp.Response?            // None = plain 500 problem; never shows details by default
  middleware : Array[Middleware]
}
pub fn ServerOptions::default() -> ServerOptions
pub fn Router::new(endpoints : Array[@endpoint.ServerEndpoint], options? : ServerOptions) -> Router raise @endpoint.DefinitionError
pub async fn Router::dispatch(self : Router, req : @mttp.Request) -> @mttp.Response noraise
pub fn Router::handler(self : Router) -> async (@mttp.Request) -> @mttp.Response noraise
pub fn Router::docs(self : Router) -> Array[@endpoint.EndpointDoc]
pub impl @mttp.Backend for Router
pub fn problem(status : Int, title : String, errors? : Json) -> @mttp.Response    // RFC 9457 problem+json
pub fn default_decode_failure(ctx : @endpoint.FailureContext) -> @mttp.Response
pub fn cors(allow_origins : Array[String]) -> Middleware
// (new) hide_endpoints_with_auth : (FailureContext) -> Response?   — a decode_failure preset (404 instead of 401)
// (new) request_id(), access_log(clock, sink)
```

The pipeline. Credentials are checked first, a deliberate deviation from tapir (P-04, **[needs-user-input]**).

1. **Route** by template. Literal segments beat captures, position by position.
   - Unknown path: 404. Known path with the wrong method: 405 with `Allow`.
   - HEAD is served by GET; OPTIONS is answered automatically.
   - Once a route matches there is no fall-through.
   - Equivalent template hierarchies must use identical capture names across methods. The shared definition checker refuses aliases such as GET `/pets/{id}` and DELETE `/pets/{name}`, so routing names stay consistent and OpenAPI cannot emit forbidden duplicate hierarchies. Rest captures follow the same naming rule after projecting their suffix away.
   - A `{name...}` rest capture with the lowest specificity is decided before P-03/P-06 freeze **[needs-prototype]**.
2. **Decode the heads** of the security and regular inputs, collecting every failure up to `max_issues`.
3. **Security head failed:** answer now. Auth atoms give 401 with `WWW-Authenticate`, others 400. The body is closed unread.
4. **`raw_body` in the security input:** buffer the body now, bounded. Over the limit gives 413 with `Connection: close`.
5. **Run `authenticate`.** An `Err(e)` answers with its declared variant; a raised error goes to `on_unhandled`.
6. **Regular head failures** answer 400 listing every problem (problem+json).
7. **Body:** content type (415), bounded read (413 + close) or stream handover, then decode and validate (400; 422 is P-05).
8. **Run the handler.** `Ok(o)` encodes as its output variant, `Err(e)` as its declared variant; a raised error is a 500 without details. Every response carries the `route_template` attribute, so request-level middleware can label metrics and spans after `next` (SC-06).

**Server body limit (new).** The effective limit is `min(adapter ceiling, Endpoint::max_body_bytes or else ServerOptions.max_body_bytes)`. The adapter ceilings are `@h1server.ServerLimits.max_body_bytes` (1 MiB) and `fetch_handler(max_body_bytes?)` (1 MiB, the default `wf2/runtime/shared/fetch` compiled). When the router knows the ceiling, `check_definitions` reports an endpoint override above it as an advisory problem.

**Request URL on the server (new).** Adapters put an absolute URL into `Request.url`, built from `serve_conn`'s `scheme~` and the `Host` header (h1server) or taken from `JsRequest.url` (fetch); Router-as-Backend already uses `http://in-process/...`. The router matches only the path.

**Router as a Backend.** The server side gets a fresh request whose attributes hold only `remote_addr = "in-process"`; the client never sees server-side response attributes (I-09, as over a socket). Bodies pass through unbuffered because both directions are pull: an SSE stream of 50 events goes through untouched, while a buffered reader with `max_body_bytes(100)` refuses with `TooLarge(limit=100)` (verified).

### 4.9 apispec and openapi

`apispec` is plain data with `derive(ToJson, FromJson)` and field renames (`in`, `type`, `$ref`). Its records are OpenApi, Info, Server, PathItem, Operation, Parameter, RequestBody, MediaTypeObject, ResponseObject (with `headers`), HeaderObject, Components, SecurityScheme and Tag. It depends only on core json. A comparator comes later. The objects gain `extensions : Map[String, Json]` (new).

```moonbit
pub fn to_openapi(docs : Array[@endpoint.EndpointDoc], info : @apispec.Info, servers? : Array[@apispec.Server]) -> @apispec.OpenApi raise @endpoint.DefinitionError
pub fn docs_endpoint(spec : @apispec.OpenApi, path? : String) -> @endpoint.ServerEndpoint
pub fn check_documented(spec : @apispec.OpenApi, template : String, meth : @mttp.Method, status : Int) -> String?
```

Projection rules (verified in `wf3/rev` unless marked):

| Concern | Rule |
|---|---|
| Paths | Client requests, projection and observed-status checks share literal-segment encoding, while capture placeholders remain intact. Dot-only literal segments are refused because transports normalize them away. |
| Request bodies | Raw-only inputs use wildcard media and their requiredness. Raw security plus a typed body preserves the typed representation and is required if either consumer is required. Absence differs from present empty bytes for raw, typed and streamed inputs. Content keys use the interpreter's case-insensitive media token without parameters. |
| Parameters | Named input parameters must be unique by name/location (header names case-insensitive). Projection refuses ordinary/signature Accept, Content-Type and Authorization header parameters because OpenAPI ignores them and would lose enforced constraints. Collection/derived inputs introduce no invented named requirements. |
| Statuses | One response object per status. Dynamic success and declared-error variants join every explicit fixed/framework status, with `default` covering the remaining final codes: explicit responses shadow default in OpenAPI. Explicit 204/304 responses omit content because the encoder strips their bodies. Content is keyed by media type. Variants with the same status and media type use inclusive `anyOf` when their schemas differ: they may overlap, so `oneOf` would reject values admitted by both. Dynamic `*/*` schemas also join specific media entries because those entries shadow the wildcard. |
| Framework statuses | Default router policy adds 400, 404, 405 and 500 per endpoint as `application/problem+json` with `$ref: #/components/schemas/Problem`, plus 401 for security-stage Auth atoms, 413 for body consumers and 415 for typed bodies. Ordinary-input Auth failures use 400. Framework representations merge with declared fixed and dynamic variants; a declared 404 and the router's 404 share one response. Custom response policies must document any additional representations themselves. |
| Schemas | Component schemas are the union of every `defs`. (new) Two different definitions under one name are refused, and every `$ref` must resolve (conformance check). |
| Response headers | `Variant::and_header`/`fixed_header` names appear under `responses.<status>.headers`. Differing header schemas use `anyOf`; a header is required only when every merged representation of that status, including framework problems, supplies it. Otherwise an omitted header would incorrectly invalidate a real response. |
| Wire schemas | Fixed headers include their constant values. SSE is a framed string (`schema`) whose events are described one by one in OpenAPI 3.2's item shape under the Media Type Object's `x-oai-itemSchema` (§0.1, references checked), rather than pretending the entire wire body is a JSON value. Item schemas of one media type merge with `anyOf`; a representation without one (a dynamic media type, for example) leaves the items unconstrained, so the merge drops it. Form fields admit scalar or repeated string values. Response Content-Type comes from the representation, since OpenAPI ignores it as a Header Object. |
| Security | All Auth atoms of one security input form **one** requirement object (AND). An all-optional security input adds `{}`. (new) `any_of` groups give OR; OAuth2 (flows, scopes, required scopes) and OpenIdConnect are added later. |
| Signatures | A `signature_header` atom is a required header parameter, never an invented scheme type. |
| Version | OpenAPI 3.1, ready for 3.2 (§0.1). |


### 4.10 driver, sim, testing and endpoint/testkit

```moonbit
// gaato/mttp/driver — experimental; the only package with %async intrinsics (one file: intrinsics.mbt)
pub fn[X] run_sync(f : async () -> X) -> X raise          // drives f to completion on virtual time; refuses, never hangs
pub fn Driver::new(auto_advance? : Bool, max_steps? : Int, start_ms? : Int64) -> Driver
pub fn[X] Driver::run(self : Driver, f : async () -> X) -> X raise
pub fn Driver::spawn(self : Driver, f : async () -> Unit, label? : String, allow_failure? : Bool) -> Task
// step, advance, advance_to_next_timer, add_timer, park, park_check_cancel, pause, sleep, cancel_and_join, live_tasks, pending_timers
pub(all) suberror DriverError { DriverError(kind~ : DriverErrorKind, detail~ : String) } derive(Debug)
#non_exhaustive
pub(all) enum DriverErrorKind { Deadlock(parked~ : Int); Suspended(parked~ : Int); NoQuiescence(steps~ : Int)
  UnwindIncomplete(live~ : Int); TaskFailed(label~ : String, cause~ : Error); MainCancelled; Reentrant; NotInTask }

// gaato/mttp/testing — imports @http and client only, so SDK tests do not compile the endpoint layer
pub fn BackendStub::new() -> BackendStub                  // expect (FIFO), when, sent, remaining, verify
pub impl @mttp.Backend for BackendStub
pub fn fail_sends(inner : &@mttp.Backend, e : @mttp.TransportError, times? : Int) -> &@mttp.Backend

// gaato/mttp/endpoint/testkit
pub fn[S, I, E, O, M] when_endpoint(stub : @testing.BackendStub, ep : @endpoint.Endpoint[S, I, E, O, M],
  respond : async (I) -> Result[O, E]) -> @testing.BackendStub raise @endpoint.DefinitionError
pub fn verify(docs : Array[@endpoint.EndpointDoc]) -> Array[@endpoint.DefinitionProblem]
```

- **Cancellation is a signal, not an Error.** The Driver delivers cancellation the way core/async does: a cancelled task unwinds through its `defer`s and the canceller observes completion, but no `Error` value is raised for user code to catch and swallow. `run_sync` reports a cancelled main task as `MainCancelled`. CONTRACT.md (Driver) holds the rules; the same contract tests run against mttp_async's runtime (§5.12).
- **One file of intrinsics.** `%async` appears only in `gaato/mttp/src/driver/intrinsics.mbt`, in a package that sets `-unused_async`. A canary diffs it against core's `async_primitive.mbt` on each toolchain (§5.6).
- **No `async test` in portable modules.** gaato/mttp tests async code with plain `test` blocks through `run_sync`, so wasm-gc runs them too (F16). Production packages never import `driver`, `sim` or `testing` (gate).
- `when_endpoint` encodes through a one-endpoint Router, so declared errors are classified as in `serve`.

### 4.11 gaato/mttp_async

Every package here opts in to the core/async packages it uses with the list form of `allow-experimental-packages`. No public signature names a core/async type (principle 9); the mbti gate checks it.

```moonbit
// runtime (native, wasm, js)
pub fn AsyncClock::new() -> AsyncClock                       // impl @rt.Clock: @async.sleep, now
pub fn ClockTimer::new(clock? : &@rt.Clock) -> ClockTimer    // impl @rt.Timer: a task group + spawn_bg
pub fn SemaphoreGate::new(permits? : Int) -> SemaphoreGate   // impl @rt.Gate: @semaphore
pub fn RuntimeCoordination::new() -> RuntimeCoordination     // impl @rt.Coordination: Cond
pub async fn[X] with_timeout_opt(clock : &@rt.Clock, ms : Int, f : async () -> X) -> X?
pub fn VirtualClock::VirtualClock(start_ms? : Int64) -> VirtualClock   // ported: discord calls VirtualClock(..) at ~230 sites
// advance, advance_to_next, next_deadline, settle(until~), pending; NoQuiescence(rounds~)

// root (native, wasm, js): shared data keeps the backend signature portable
#non_exhaustive
pub(all) enum Trust { System; Insecure; PemFile(String) } derive(Eq, Debug)
// conn (native, wasm)
pub fn TcpDialer::new(trust? : @http_async.Trust) -> TcpDialer // impl @rt.Dialer
// connect: Tcp::connect_to_host; start_tls: Tls::client(ConnIo(&Conn), host~, trust~). ConnIo implements core's
// Binary*Impl over any &@rt.Conn, so TLS runs over a plain socket or inside a CONNECT tunnel alike.
// Half-close: core has no shutdown-write API, so Conn has none; the adapter documents it as unavailable.

// server (native, wasm)
pub(all) suberror ListenError {                              // frozen at release
  Config(@h1server.ServerConfigError)                        // limits refused before binding or on_listen
  Bind(detail~ : String)
  Accept(detail~ : String)
} derive(Debug)
pub async fn serve(handler : @mttp.Handler, addr~ : String, on_listen? : (String) -> Unit,
  limits? : @h1server.ServerLimits, on_error? : (@mttp.TransportError) -> Unit) -> Unit raise ListenError
// TcpServer accepts; each connection goes to @h1server.serve_conn with scheme~="http"

// backend (native, wasm, js)
pub fn AsyncBackend::new(config? : @h1client.ClientConfig, trust~ : @http_async.Trust = System,
  clock? : &@rt.Clock, timer? : &@rt.Timer) -> AsyncBackend
// Defaults: AsyncClock and ClockTimer on the chosen clock. Socket pool expiry and
// phase deadlines use these ports; JS uses them for upload/head/body deadlines.
// On JS only config.max_body_bytes applies; trust and socket phase settings are ignored.
pub impl @mttp.Backend for AsyncBackend                      // idle_connections
// native/wasm: @h1client.Client over TcpDialer, AsyncClock, ClockTimer, RuntimeCoordination, always wrapped in Decompress
// (a request that sets its own Accept-Encoding opts out, per the table below)
// js: fetch over core's js_async; one type, so callers never branch on the target

// codings (native, wasm, js)
pub fn coding_plan(content_encoding : String) -> Array[Coding] raise @mttp.TransportError     // <= 5 codings
pub fn ContentDecoder::new(plan : Array[Coding]) -> ContentDecoder raise @mttp.TransportError  // feed, pull (<= 64 KiB), end
pub fn ContentEncoder::new(c : Coding) -> ContentEncoder raise @mttp.TransportError           // gzip, deflate, br; zstd decode-only
pub fn negotiate_encoding(h : @mttp.Headers) -> EncodingChoice raise @mttp.TransportError
pub fn Decompress::new(inner : &@mttp.Backend) -> Decompress  // (new) impl @mttp.Backend
pub fn compress(handler : @mttp.Handler, min_bytes? : Int) -> @mttp.Handler   // (new) negotiates and encodes responses

// fetch, hosts (js)
#external pub type JsRequest
#external pub type JsPromise
#external pub type JsBackground
#external pub type JsEnv
pub let env : @mttp.AttributeKey[JsEnv]
pub fn fetch_handler(handler : @mttp.Handler, max_body_bytes? : Int) -> (JsRequest, JsBackground) -> JsPromise
// MoonBit entry: `pub let fetch = ...` is not exported (F20); write `pub fn fetch(req, bg) { h(req, bg) }`
```

**Decompress** (replaces the `decompress` option):

| Case | Behaviour |
|---|---|
| Request without `Accept-Encoding` | Sends `Accept-Encoding: gzip, deflate, br, zstd`, undoes the codings in 64 KiB pulls, removes them from `Content-Encoding` and drops `Content-Length`. An unknown coding stays on the body untouched. |
| Request with its own `Accept-Encoding` | Sent as is; the body comes back as sent. |
| No wrapper | The engine never touches codings; bytes pass through. |
| JS | fetch always negotiates and decodes; a per-target CONTRACT exception. |

The wrapper passes SendOptions through unchanged, so the engine caps **wire** bytes; the mttp Client's reader caps **decoded** bytes (§4.4). Neither layer trusts the other's count.

**compress** encodes a response only when the request's Accept-Encoding allows it, the response has no Content-Encoding, is not a 101/204/304 and is large enough; each input chunk is sync-flushed and each pull yields at most 64 KiB.

**Targets.** wasm means wasm1 under moonrun only. wasm-gc has no core/async: types, codec, engines and the policy layer run there, and a wasm-gc application that needs the network supplies its own `rt` implementations (the README says so).

**fetch behaviour** (kept from PR #2): the handler calls the `JsBackground` callback once, synchronously, at request entry, with one aggregate promise that settles when all work started through the `background` attribute has finished. `JsRequest.signal` maps to handler cancellation. Host shims:

| Host | Shim |
|---|---|
| Cloudflare Workers | `export default { fetch(req, env, ctx) }` passes `p => ctx.waitUntil(p)` and sets `env` |
| Fastly Compute | registers the promise with `event.waitUntil` synchronously, before `event.respondWith` |
| Vercel | `waitUntil` from `@vercel/functions` |
| Deno, Bun | a tracker that keeps the promise alive |
| AWS Lambda URLs | builds a Web `Request` from the event, passes `undefined` as the body when the event has none (so the handler sees `Body::Empty`), and awaits the background promise before returning |

### 4.12 Codegen

- **mbt-sdk tools/gen (Python) stays.**
- **Phase 1** retargets the emitter mechanically:
  - `@mttp.Request::get/post/put/patch/delete(path)` from gaato/mttp 0.5 becomes the same call on gaato/mttp 0.6 with `Method` values; anything else becomes `@mttp.Request::new(@mttp.Method::parse("X"), path)`. `.json_body` becomes `.body_json`; `@multipart.apply(request, parts, boundary)` becomes `@multipart.body(request, parts, boundary~)`.
  - Generated `*_request` functions stay non-raising, except multipart operations, which keep `raise @multipart.MultipartError` and their explicit `boundary` parameter. Hand-written facade encoders raise `@client.InvalidRequest`.
  - Decoders become `*_decode(head : @mttp.ResponseHead, body : Bytes) -> Result[T, @client.ResponseFailure]`, used as `@client.ResponsePlan::new((h, b) => @gen.x_decode(h, b))` or through `map_ok`, so 403/429 still reach the retry decision as values.
  - `@sdkjson` imports `gaato/mttp/jsonkit` directly (qualified constructors do not resolve through `pub using`, E4021).
  - The output is regenerated, not hand-edited.
- **Phase 2** (opt-in, later): Endpoint values as `pub let`; needs header outputs, nesting beyond map8 and multipart bodies.
- **`gaato/mttp-gen`** is dropped until a consumer exists (F51).

## 5. Cross-cutting concerns

### 5.1 Error taxonomy

| Error | Package | Raised or returned by | Meaning / handling |
|---|---|---|---|
| `TransportError(kind~, phase~, detail~)`, `#non_exhaustive Kind` | http root | Backend::send, BodyStream::read_some, rt ports, engines, wrappers, the Client's deadlines, SseParser, a second take of a stream body; passed to server `on_error` | No usable response, the bytes did not move, or a policy refused (sttp SttpClientException). `is_unsent` gates resends. |
| `UrlError` | http root | `Url::parse`, `percent_decode` | Engines map it to `Kind::Invalid`, phase Pool (unsent). |
| `ResponseFailure::{UnexpectedStatus, Deserialization}` | client | built-in readers, as a **value** | A response we did not want (sttp ResponseException). Diagnostic bodies capped at 1 MiB. |
| `InvalidRequest(message~)` | client | facade encoders, `Endpoint::request` | The request could not be built and was never sent. |
| `MultipartError` | multipart | `body`, `encode_segments_fresh`, generated multipart `*_request` | Raised before anything is sent. |
| any user error | readers (`map`), callbacks | user code | Keeps its identity; never converted. |
| `DecodeFailure(kind~, message~)` / `InputErrors` | schema / endpoint | decoders | Mapped to 400/401/413/415 by the decode-failure table. |
| `UnsupportedPattern` | schema | `pattern(ecma)` | Refused when the validator is built. |
| declared `E` | endpoint | handlers and `authenticate`, as `Err(e)` **values** | Encoded as its declared variant; the client returns the same value in the inner `Result`. |
| `DefinitionError` | endpoint | Router::new, to_openapi, `verify` | Bad definitions are refused at construction. |
| `h1.ParseError(kind~, detail~)` | h1 | codec | 431, 400 or 501, with close. |
| `ServerConfigError` | h1server | `ServerLimits::validate` | Invalid limits, before any connection is served. |
| `ListenError::{Config, Bind, Accept}` | mttp_async/server | `serve` | Configuration and listening failures. |
| `DriverError(kind~, detail~)` | driver | `run_sync`, `Driver::run`, `step` | The computation needed a real event source, deadlocked or could not unwind. |
| `NoQuiescence(rounds~)` | mttp_async/runtime | `VirtualClock::settle` and friends | The simulated tasks never settled. |

Cancellation is never converted into another error, and no test asserts on `detail` text, which differs across targets.

### 5.2 Resource bounds

All byte limits are `Int` (≤ 2 GiB); lengths are `Int64`. Wire and decoded bytes are separate bounds with separate RESOURCE_BOUNDS rows (`bounds_check`, §5.13).

| Bound | Default | On overflow |
|---|---|---|
| Buffered client body, **wire** bytes (engine, `Exchange(max_bytes)`, min with `ClientConfig.max_body_bytes`) | the Client's `max_body_bytes` | `TooLarge`, phase Body, at the crossing chunk; the connection is discarded |
| Buffered client body, **decoded** bytes (mttp Client reader) | 64 MiB | `TooLarge`, phase Body, at the crossing chunk |
| Decoder output per pull | 64 KiB per stage | returned in slices; never eagerly decoded |
| Content codings | ≤ 5 stages; windows: DEFLATE 32 KiB, Brotli ≤ 16 MiB, zstd ≤ 8 MiB | Protocol |
| Diagnostic body in `UnexpectedStatus` | 1 MiB | truncated for the failure value only |
| SSE event | 16 MiB | `TooLarge(limit)`, phase Body |
| Line reader | 1 MiB | `TooLarge(limit)`, phase Body |
| Head, both engines (`h1.Limits`) | 16 KiB incl. CRLF, 100 fields | 431 + close (server); `Protocol`/`TooLarge`, phase Head (client) |
| Chunk-size line / trailers | 4 KiB / 16 KiB, 100 fields | 400 + close (server); phase Body (client) |
| CONNECT answer | `h1.Limits` | refused in phase Dial before TLS |
| CL+TE, duplicate or invalid CL | rejected | 400 + close |
| Redirect hops | 10 | `TooManyRedirects`; each 3xx body closed unread |
| Cookies | 50 per domain, 3000 total, 4096 B, 400 days | dropped per RFC 6265 |
| Retries | per policy and `total_ms` | stop with StopReason |
| Server-specified waits (rate limits, Retry-After) | 1 hour | clamped |
| Idle pool | 256 total, 4 per origin, 10 s | closed |
| Active client connections | unset; caps below 1 count as 1 | queued until a slot, Pool timeout, cancellation or close |
| Socket reads and writes | 64 KiB | sliced |
| Server request body | `min(adapter ceiling, endpoint override or router default)`; 1 MiB each | 413 + `Connection: close` |
| Server header / body timeout | 5 s / 5 s; optional handler deadline; 10 s drain | 408/504 + close |
| Server connections | 256 | not accepted until a slot frees |
| Drain of an unread body | 64 KiB | close instead |
| Query pairs / path segments | 256 / 64 | 400 / 404 |
| Issues collected per request | 100 | truncated with a marker |
| JSON nesting, recursive codecs | 128 / 128 | Malformed / depth issue |
| JS upload buffer / delivery slice / empty host chunks | 16 MiB / 64 KiB / 1024 | refused |
| Lambda buffering | 1 MiB in / 4 MiB out | refused / reader cancelled |
| Digest challenge / nonce origins | 16 KiB / 16 | 401 returned unchanged / oldest evicted |
| Driver steps / unwind rounds | 100 000 000 / 8 | `NoQuiescence` / `UnwindIncomplete` |

The old "client response head unbounded" row (F63, risk 20) is gone: the h1client engine parses responses with `h1`.

### 5.3 Time and randomness

Every policy takes `&@rt.Clock`, and where needed `&@rt.Timer`, `&@rt.Gate` and `random : () -> Double`: the Client loop, CookieJar, WindowLimiter, the multipart boundary, access logs and both engines. Portable tests use `@sim` doubles under `@driver.run_sync`; runtime tests use mttp_async's VirtualClock.

### 5.4 Streaming, SSE and WebSockets

- **One direction: pull.** Bodies are pull `BodyStream`s in both directions, so the CONTRACT rules and the conformance harness stay single.
- **Server SSE.** A handler returns an `EventStream[T]` through `sse_out`; the endpoint encodes it as a stream; the adapter writes it with backpressure; Router-as-Backend passes it through unbuffered.
- **No push bodies.** A producer-style handler bridges through a runtime queue in the application.
- **Client SSE.** `as_sse` with a `stop` predicate for sentinels such as OpenAI's `data: [DONE]`.
- **WebSockets** stay deferred (§0.2). When added: a 101 Response carrying the upgrade callback in an attribute, a sans-IO frame codec in gaato/mttp, `WebSocketStub` in sim, and scheme validation before any runtime call.

### 5.5 Target matrix

| Unit | wasm-gc | wasm | js | native |
|---|---|---|---|---|
| all of gaato/mttp (incl. engines; async tests via `run_sync`) | ✓ | ✓ | ✓ | ✓ |
| all of gaato/mttp, gaato/mttp_digest | ✓ | ✓ | ✓ | ✓ |
| mttp_async/codings | – | ✓ | ✓ | ✓ |
| mttp_async/runtime, backend | – | ✓ (moonrun) | ✓ (request bodies buffered, ≤ 16 MiB) | ✓ |
| mttp_async/conn, server | – | ✓ | – | ✓ |
| mttp_async/fetch, hosts | – | – | ✓ | – |

CI lists packages per target and **asserts the test count per package and target** (F16). gaato/mttp must produce the same mbti on all four targets.

### 5.6 Churn policy

- **Toolchain.** Pinned to 0.10.20+65efd5b93 (`moonbit-version`); `moon self-update` is not used. Daily canaries run the latest toolchain and diff `driver/intrinsics.mbt` against core's `async_primitive.mbt`, so an intrinsic change is seen before it breaks the Driver.
- **Warnings.** `moon check --deny-warn` on all targets. Async-typed parameters take arrow lambdas (F6, F54); the driver package sets `-unused_async`.
- **Deprecated forms** the toolchain warns about (`#derive`, `clamped_view`, `Map([])`, `Json(v)`, `to_owned`, Debug instead of Show) are fixed at once, and the generators emit the new forms.
- **Snapshots.** mbti per package and target; diffs are reviewed in every PR.
- **Containment.** Runtime API churn stays in mttp_async (its `internal/` adapters). Intrinsic churn stays in one file of `driver`.
- **Evolution rules.**
  - **(a) Enums.** `#non_exhaustive` on Body, Method, Kind, Phase, BodyTiming, `@retry.Decision`, ResponseFailure, DecodeKind, AuthScheme, Location, FailureStage, h1 Framing, ParseKind, Version, Trust, DriverErrorKind, and any later enum that may grow.
  - **(b) Structs.** Downstream code builds `pub(all)` structs through `::new`/`::default()` plus record update. Field sets frozen at release: Request, Response, RequestHead, ResponseHead, SendOptions, RetryContext, RetryPolicy, RedirectConfig, Attempt, Reply, SseEvent, multipart Part, RetryRule and its records, GlobalWindow, Pace, RateLimitState, Page, h1 Limits, ClientConfig, ServerLimits, DispatchContext, FailureContext, DefinitionProblem, InputFailure, Schema, Issue, ServerOptions, apispec records.
  - **Read-only instead of frozen.** ParsedRequest, ParsedResponse, Decoded, Atom, VariantDoc and EndpointDoc are read-only `pub`, so they can grow.
  - **(c) Suberrors.** A suberror that may grow takes the kind form: TransportError, DecodeFailure, ParseError, DriverError. Every other suberror is frozen at release: InvalidRequest, MultipartError, UnsupportedPattern, InputErrors, DefinitionError, ServerConfigError, ListenError, NoQuiescence.
  - **Opaque structs.** `Out`, `Variant`, `ResponsePlan`, `RequestPlan`, `Input`, `Staged`, `RequestSink`, the engines' `Client` and the Driver can change internally without breaking.

### 5.7 Testing and conformance

| Suite | Where | What |
|---|---|---|
| In-package | every gaato/mttp package | plain tests through `run_sync` on all 4 targets |
| Engines over sim | `h1client`, `h1server` | Pool, slots, deadlines, proxy, CONNECT/TLS event order, early responses, half-close, peer failure, 1/17/65536-byte fragmentation, hostile heads and chunk lines, slow headers, floods, drain, 100-continue, disconnect cancellation — on all 4 targets. PR #2 checked most of this only over sockets (53 client and 31 server tests against 5 and 6 portable ones); the rebuild moves them onto sim + Driver. |
| Contracts | `sim` checkers | Conn, Coordination, BodyStream and Backend contracts, run against the sim doubles and against mttp_async's adapters |
| Cross-layer gate | `conformance` | definition package → Router → `Endpoint::call` through `Client`; 200/400/401/403/404/405/413/415/500, retries, SSE, `when_endpoint`, OpenAPI |
| Corpora | `conformance` | SSE, http-state cookies, WPT URL, form decoding, router path matching, **h1 smuggling and split-read corpus**, ECMA pattern translation, `$ref` resolution |
| Sockets | mttp_async packages (native, wasm) | loopback, verified and nested TLS, proxy, coding and upload suites; listener; adversarial probes against `serve` |
| JS | mttp_async (js) | Node host-shim tests, Lambda empty-body POST, `scripts/browser_gate.mbtx` |
| End to end | `examples` | `get` (status, headers, gzip and br bodies on native and wasm), `serve` with curl (keep-alive 200; 20 KiB header → 431; CL+TE → 400), `fetch` |
| Release | CI | `--deny-warn` on all targets; resolver gate; per-target test counts; mbti equality; coverage ledger |

### 5.8 Versioning and release

Facts the rules rest on (F26–F33): moon selects, per module, the **highest of the declared minimums**. moon.mod accepts only plain `X.Y.Z` minimums. All 0.x and 1.x versions share one compatibility set; only a new path (`/v2`) can coexist. Deprecation is module-wide and advisory, and does not affect selection; there is no per-version yank. Workspace members override requirements.

| Rule | Why |
|---|---|
| A patch or security fix reaches dependents only when they raise their minimum. Every gaato dependent raises it in the same train. | MVS never upgrades on its own (F26). |
| **Flag-day rule for gaato/mttp 0.6.** It is published in the same release train as the SDK re-releases (openai, anthropic, github) and their consumers, never ahead of them. openai, anthropic, github and sdk-runtime depend only on gaato/mttp 0.5, and 0.5 and 0.6 are one compatibility set: once anything in a graph requires 0.6, every 0.5-only library in it breaks. | One compatibility set (F28). |
| No breaking 0.x release is "contained". A later breaking gaato/mttp minor is a new flag day for every module that imports it. | F28 |
| **Old-stack graphs are frozen.** Graphs that hold gaato/mttp ≤ 0.5, mttp_async ≤ 0.5, sdk-runtime, requesto ≤ 0.2 or discord ≤ 0.13 get no further releases on those lines; they keep resolving as they do today and cannot be combined with the new stack. | §0.1 (G-06 option (b)); F35 |
| mttp and mttp_async are versioned independently. They share only gaato/mttp, so neither needs the other's minor (the F29 hazard is gone). | Principle 8 (b) |
| `gaato/mttp/v2` and `gaato/mttp/v2` are the escape hatches. | Only a new path coexists (F28). |
| **Resolver gate:** each published module is resolved and built from a scratch consumer outside moon.work; the gate also checks that using an experimental package from outside requires the opt-in. A version is bumped whenever moon.mod imports change. | Workspace members hide real resolutions (F30). |
| Deprecate a module only after its last gaato dependent moved; publish nothing to it afterwards. gaato/mttp and mttp_async are **not** deprecated: their 0.6 is the future of the same path. | F27 |
| No moon.mod lists `gaato/mttp-gen`. | F51 |

### 5.9 Naming

| Rule | Reason |
|---|---|
| The field is `meth` | `method` is reserved and warns |
| `input`/`output`/`security`/`errors` builders | `in` is a keyword |
| `ignore_body`, never `ignore` | shadows the prelude |
| `router` (not `server`) in mttp; `endpoint/testkit` (not `testing`); `jsonkit` (not `json`); `sim` (not `testing`) in gaato/mttp | duplicate package aliases warn |
| `@h1client.Client` vs `@client.Client` | different layers; always used through their aliases |
| `Reply[T]`, `@retry.AttemptOutcome` | avoid a second Response and a third Outcome |
| Rename `moonbitlang/core/async/http` (for example `@corehttp`) wherever it meets the root `@http` | equal default aliases (§3.2) |
| No "tapir" or "sttp" names in the API | the family is mttp |

### 5.10 Mechanisms removed

| Removed | Replacement |
|---|---|
| `RequestOptions` (`timeout_ms`, `body_deadline`, `read_idle_ms`, `max_body_bytes`, `follow_redirects`, `max_redirects`, `decompress`) | `@mttp.SendOptions { timeout_ms, body : BodyTiming }`; the Client's `timeout_ms`/`max_body_bytes`/`read_idle_ms`; redirect knobs → `RedirectConfig` on FollowRedirects plus the per-request `redirect_limit` attribute; `decompress` → the `@codings.Decompress` wrapper |
| `ServeError` (a struct passed to `on_error`) | `@mttp.TransportError` |
| `ServerConfigError::{Bind, Accept}` | `@server.ListenError::{Bind, Accept}`; configuration problems as `ListenError::Config` |
| `serve(compression?)`, `serve_conn(compression?)` | `@codings.compress(handler)` |
| `H1Backend` in `mttp-net/backend` and `mttp-net/h1/client` (duplicates of the engine), `mttp-net/h1`, `mttp-net/h1/client`, `mttp-net/h1/server` | `@h1client.Client`, `@h1server`; `AsyncBackend` as the one I/O backend |
| `mttp-net/quick`, `client.quick_request`, root `new_client` (mttp-net) and the empty root `gaato/mttp` facade | none in the family; `moonbitlang/core/async/http` for trusted throwaway use (§0.1) |
| `testing.run_sync`, `testing/driver`, `testing/conn`, `testing/feed`, `testing/gen`, `clock/fake` | `@driver`, `@sim` |
| `@client.Backend`, `@model`, `@clock`, `@conn` | `@mttp.Backend`, `@http`, `@rt` |
| Vendor retry presets in the core (`stainless`) | the SDK that needs them |
| Header-only idempotency (`Idempotency-Key`) | method or `replay_safe` |
| Exception-first readers (`ResponseAs` raising `ResponseError`), `classify` for declared errors | Result readers with `ResponseFailure`; declared errors as values |
| From the 2026-10-24 drafts (still removed) | `PartialRequest`, `RequestBuilder`, `basic_request`, `WebSocketRequest`; Policy-as-value; `layer`; `as_*_always`, `as_either`; `ReadMode`; `ServerBody::Push`, `EventStream::from_producer`; `ServerResponse`, `Outcome`; `RouteError`, `EndpointDefinitionError`; five body-limit knobs; Workers-shaped `fetch_handler`; `serve_result`; `RecordingBackend`; ChallengeAuth/Digest in the core; the gaato/clock and gaato/jsonkit modules; the forward 0.5.1 shim; DeadlineTransport |

### 5.11 Layers inside the engines

| Layer | Owns | Examples |
|---|---|---|
| Pure decisions | Immutable snapshots, persistent collections, returned effect descriptions | retry and redirect plans; admission counts and queued ids; idle-pool metadata; peer EOF/failure; listener shutdown |
| Local parsing and orchestration | One reader's mutable buffers and cursors; interpretation of decisions against injected ports | h1 decoders, request/response bodies, the h1client and h1server engines |
| Runtime adapters | TCP/TLS, time, scheduling, resource handles, wait/wake/close/cancel | TcpDialer, RuntimeCoordination, ClockTimer, the listener |

Binding rules:

- `internal/control` contains no sockets, tasks, waiters, callbacks, async functions, `mut` fields or `Ref`s (gate). Each transition returns a new state and leaves old states usable; persistent HashMap/Vector updates avoid copying a whole pool per event.
- Adapters keep a separate id-to-resource table and **commit a transition before interpreting its actions** (close, cancel, wake). Local builders never escape into states.
- The engines are portable orchestration, not pure functions: they call Conn, Dialer, Clock, Timer and Coordination. Parsers still mutate private buffers, because a persistent buffer per input byte would cost more without strengthening the ownership contract.
- Retry and redirect planning consume snapshots (RequestHead plus explicit idempotency and replayability). Body reuse and closure happen outside the planner. Capturing availability never authorizes resending a stream: the Client still needs a body factory.

### 5.12 Expected failure modes and their prevention

| Failure mode | Prevention by types and structure |
|---|---|
| Request smuggling (CL with TE, duplicate CL) | Both engines use the same `request_framing`/`response_framing`; `Smuggling` is 400 and close. Checked by the h1 conformance corpus. |
| Memory exhaustion (head, chunk line, trailers, body, decompression bomb) | Limits, ServerLimits and ClientConfig always carry default bounds. `Exchange(max_bytes~)` cannot be built without a limit. Decoding runs in 64 KiB pulls, and decoded bytes have their own bound (§5.2). |
| A non-idempotent request resent after it was sent | `Phase` drives `is_unsent`. Stale-connection repair resends only requests with a replayable body that are idempotent or marked `replay_safe`; the Client loop never resends a stream without a body factory. |
| Two runtimes linked into one process | Only mttp_async imports core/async; the gate forbids `moonbitlang/async` everywhere. |
| Experimental API leaking into the stable layer | `experimental: true`, list-form opt-in, and the gate's allow list. |
| Runtime types in a public API | An mbti grep gate over every module; ports are `@rt` traits. |
| Cancellation swallowed | Cancellation is a non-Error signal; contract tests run against the Driver and against mttp_async's runtime. |
| Connection or slot leaks | StreamBody is taken once; `close_if_unclaimed`; sim and the Driver count live connections and tasks at the end of each test. |
| An absent body confused with an empty one (two PR #2 review findings) | Framing decides `Body::Empty` versus `Stream`; the endpoint checks `Empty` first; the Lambda shim passes `undefined` for a missing body. |
| mttp and mttp_async drifting apart | They share only gaato/mttp; the resolver gate builds both from outside. |
| A toolchain changing the intrinsics | One intrinsics file; a canary diffs it against core's `async_primitive.mbt`. |

### 5.13 Gates

Module-level allowed imports live in `scripts/modules.tsv`; the gates read it, so adding a package is a data change.

| Gate | Checks |
|---|---|
| `architecture_gate` | gaato/mttp imports no module and no `core/async*` or `core/compress*` package, and contains no `extern` and no `async test`. gaato/mttp_digest imports only gaato/mttp, moonbitlang/x and core; gaato/mttp_async only gaato/mttp, core and the codec modules. The engines never import codings. `moonbitlang/async` is forbidden everywhere. `internal/control` has no `async fn`, `mut` or `Ref`. `allow-experimental-packages` is always a list. |
| `runtime_gates` | No public mbti of any module names a runtime type. gaato/mttp produces identical mbti on all four targets. Test counts per package and target are pinned. |
| `test_layout` | `%async` appears only in `mttp/src/driver/intrinsics.mbt`. No production package imports `driver`, `sim` or `testing`. |
| `bounds_check` | Every RESOURCE_BOUNDS row names an existing test; wire and decoded bytes are separate rows. |
| `resolver_gate` | The library modules resolve and build from a scratch consumer outside moon.work; an experimental package needs the consumer's opt-in. |
| `type_contracts` | Compile-fail fixtures from an external package: a Streaming endpoint refuses a Buffered request; `as_both` refuses streaming readers. |

`scripts/*.mbtx` move to core/async's `fs` and shell APIs. A `.mbtx` script cannot set the experimental opt-in (front matter accepts `import` and `permission` only), so it runs with the experimental warning on stderr, which `scripts/gates.sh` filters. The shared `docs_audit.mbtx` was the last script on moonbitlang/async 0.22.5; it moved in every gaato repository on 2026-11-10, and the gate has no exemption left.
## 6. sttp/tapir concept map

| sttp / tapir concept | mttp home, or the reason it is omitted |
|---|---|
| sttp-model Uri, UriInterpolator | `@mttp.Url` (WPT parser) + string targets; `UriBuilder`/`UriPart` |
| Method, StatusCode, Header(s), MediaType, Request/ResponseMetadata | `@mttp.Method`, Int status + helpers, `Headers`, `MediaType`, `RequestHead`/`ResponseHead` |
| Part, ServerSentEvent, CookieWithMeta | `multipart`, `sse`, `cookie` |
| sttp-shared MonadError, F[_], Streams capability | omitted: direct-style async, one `BodyStream` |
| sttp-shared AttributeMap | `@mttp.Attributes` (typed keys) on Request and Response; no type-keyed map (no TypeId) |
| client4 PartialRequest / Request / RequestBuilder; basicRequest | `@mttp.Request` builders + `RequestPlan[T, M]` (`@client.request`, `get`, `post`); Client defaults replace the template value |
| quickRequest / simple client | omitted (§0.1); `moonbitlang/core/async/http` for trusted throwaway use |
| ResponseAs: asString, asJson, asEither, fromMetadata, ignore, asStream*, asBoth, asParams, asFile | `ResponsePlan` with a Buffered/Streaming mode: `as_string`, `as_json` (Result values), `ResponsePlan::reject`/`any_status`, `from_head`, `ignore_body`, `as_stream`, `as_both`, `as_form`; `as_file` later (mttp_async) |
| Backend / StreamBackend / SyncBackend | `@mttp.Backend` (always pull bodies; `BodyTiming` says buffered or streamed); no sync split |
| WebSocketBackend, WebSocketStub | later (§5.4) |
| RequestOptions, maxRedirects, redirectToGet | `@mttp.SendOptions` (set by the Client from its defaults and per-request overrides); `RedirectConfig` on FollowRedirects + the `redirect_limit` attribute |
| compressBody / compression | `@codings.Decompress` (client) and `@codings.compress` (server) in mttp_async; request compression later |
| SttpClientException / ResponseException | `TransportError` (raised) / `ResponseFailure` (a value) |
| FollowRedirectsBackend | `FollowRedirects` (final URL and history as response attributes) |
| DigestAuthenticationBackend | `gaato/mttp_digest` (`DigestScheme`) |
| ResolveRelativeUrisBackend | `Client` base_url (prefix join, not RFC 3986) |
| ListenerBackend, LoggingBackend, OTel/Prometheus | `Client` observer (per attempt) + `from_fn`; `on_attempt_start`, header redaction helper later |
| CachingBackend | later, as a bounded Backend wrapper, or an explicit omission |
| RetryWhen, resilience | `RetryDecider` over the decoded outcome + `client/retry` + the Client loop |
| EitherBackend, TryBackend, MappedEffectBackend | omitted: they exist only for F[_] |
| BackendStub / RecordingBackend | `testing.BackendStub` (`sent` replaces RecordingBackend) |
| ToCurlConverter | `RequestPlan::to_curl` (Buffered plans) |
| Proxy (HTTP/SOCKS) | `h1client`: HTTP CONNECT only (TLS inside the tunnel via `ConnIo`) |
| tapir Endpoint, EndpointInput/Output/IO | `Endpoint`, `Input` (atoms + staged), `Out`/`Variant` |
| ParamConcat, `.in(a).in(b)` | set-once builders + map2..map8; nest pairs beyond 8; a derived input later |
| path DSL, paths (rest) | OpenAPI templates + typed `path`; `{name...}` + `paths(name)` [needs-prototype] |
| header / setCookie / statusCode outputs, emptyOutputAs | `and_header`, `fixed_header`, `and_status`, `set_cookie` |
| extractFromRequest, clientIp, queryParams, headers | `attribute(key)`, `client_ip`, `query_params()`, `headers()` |
| Codec, Schema, Validator, Schema.derived, SRef | `schema` package; `recursive`; mttp-gen later |
| oneOfUsingField / discriminator | `tagged` + `case_` (verified in `wf2/completeness/schema/src/fix/union.mbt`) |
| DecodeResult | raised `DecodeFailure`/`InputErrors` inside input decoding; client results as `Result[Result[O, E], ResponseFailure]` |
| oneOf / oneOfVariant | `one_of` + `Variant::contramap`; same status tried in order |
| oneOfBody, NotAcceptableInterceptor (406) | later; non-breaking because `Out` is opaque |
| serverLogic / serverSecurityLogic / PartialServerEndpoint | `serve` / `serve_public` with `Result`-returning handlers; no PartialServerEndpoint type |
| serverLogicRecoverErrors | `serve` (declared errors are `Err` values) |
| ServerInterpreter | `ServerEndpoint::dispatch` + `Router` (credentials-first deviation) |
| DecodeFailureHandler / RejectHandler / ExceptionHandler | `decode_failure` / `reject` / `on_unhandled` (returns a Response) |
| hideEndpointsWithAuth | `hide_endpoints_with_auth` preset (new) |
| RequestInterceptor / EndpointInterceptor, metrics | `Middleware` + the `route_template` response attribute; `on_body_end` later |
| CORS interceptor | `cors` middleware |
| SttpClientInterpreter | `Endpoint::request` / `call` / `call_with` |
| TapirStubInterpreter / sttp-stub4-server | `impl Backend for Router` + `testkit.when_endpoint` |
| EndpointVerifier | `testkit.verify` (= `check_definitions`) |
| OpenAPIDocsInterpreter / sttp-apispec / Comparator | `openapi.to_openapi` / `apispec` / comparator later |
| Examples, docs extensions, Input default, deprecated params, docs UIs (swagger, redoc) | later (SC-13) |
| auth.bearer/basic/apiKey; oauth2; openIdConnect | `bearer`, `signature_header`, basic, api keys; OAuth2/OIDC later |
| multipartBody (client and endpoint) | client: `@multipart.body`; endpoint: `stream_body_out` for replies, multipart input later |
| static files (files module) | later: `mttp_async/files` + sans-IO conditional/Range helpers |
| streamBody / serverSentEventsBody / webSocketBody | `stream_body` / `sse_out` + `EventStream` / later |
| server backends (netty, jdkhttp), serverless | `mttp_async/server` (over `h1server`), `mttp_async/fetch` + `hosts` (Workers, Fastly, Vercel, Deno, Bun, Lambda URLs); `h1server.serve_conn` for any other runtime |
| openapi-codegen | mbt-sdk tools/gen (Python) |
| AsyncAPI | omitted for now **[needs-user-input]** |
| per-integration modules (zio, cats, circe, ...) | omitted: one runtime, one JSON |


## 7. Implementation plan

The tiers of the 2026-10-24 design (v0.1 client half, v0.2 requesto parity, v0.3 experimental endpoint layer, v0.4 OpenAPI) were all implemented on PR #2 and stay in scope; what changes is the module layout and the order of review. "Later, on demand" stays as it was: WebSockets, a multipart reader and endpoint multipart input, static files, 406 negotiation, OAuth2/OIDC, a docs UI, a caching backend, request compression, file bodies, mttp-gen, a public sync client half, HTTP/2, AsyncAPI.

### 7.1 The PR stack

Each PR branches from the previous one, stays at about 5k changed lines or fewer, and passes `scripts/gates.sh full` on its own. A PR merges after its gates pass and its Codex review findings are resolved. "Bounds" lists the RESOURCE_BOUNDS rows the PR must register, each naming a test that drives the structure to its limit and one past it.

| # | Scope | Bounds to register |
|---|---|---|
| 1 | This design, CONTRACT.md | — |
| 2 | Workspace and gates: `moon.work` (http, http-async, mttp, mttp_digest, conformance, examples), module skeletons, scripts ported to core/async, `scripts/modules.tsv`, CI and release for four modules, the experimental opt-in probe; empty RESOURCE_BOUNDS.md and TEST_COVERAGE.md skeletons so `bounds_check` runs from the start | — |
| 3 | `http/rt`, `http/driver`, `http/sim` | Driver steps per run, unwind rounds, timer callbacks per run, cleanup steps per round; generator size clamps |
| 4 | `http` root vocabulary, `Backend`, `SendOptions`/`BodyTiming` | `read_bounded`; StreamBody declared length; `form_urldecode` pairs (256) |
| 5 | `http/h1` with the struct API and the smuggling and split-read corpus | head bytes and fields (16 KiB, 100); chunk-size line (4 KiB); trailer bytes and fields (16 KiB, 100) |
| 6 | `http/internal/control` and the h1client core (pool, slots, wire, body, deadlines) with sim tests | idle pool (256 total, 4 per origin, 10 s) and origin index; active-connection caps and queued waiters; 64 KiB reads and writes; buffered **wire** bytes (`Exchange.max_bytes`, `ClientConfig.max_body_bytes`); response head/chunk/trailer ingestion through `h1.Limits` |
| 7 | h1client proxy, CONNECT, NO_PROXY, uploads and early responses | CONNECT answer ingestion; TLS layers (one origin, at most one proxy) |
| 8 | `http/h1server`, `ServerLimits`, hostile-input tests over sim (slow heads, floods, drain, 100-continue, disconnect cancellation) | server heads (16 KiB) and accepted connections (256); read-ahead and 64 KiB writes; drain (64 KiB); header/body/handler/drain durations; adapter body ceiling (1 MiB) |
| 9 | mttp `jsonkit`, `sse`, `multipart`, `cookie`, `internal` | SSE event (16 MiB); cookie entries (50/3000), name/value and attribute bytes (4096/1024), lifetime (400 days); multipart boundary scan |
| 10 | mttp `client` (loop, wrappers, `from_fn`, Retry-After and Link), `client/retry`, `testing` | buffered **decoded** bytes (64 MiB); diagnostic excerpt (1 MiB); line reader (1 MiB); call duration (`timeout_ms`, `total_ms`) |
| 11 | mttp `client/ratelimit`, `client/cookies`, FollowRedirects config, Paginator | redirect hops (10); server-specified waits (1 hour); paginator collection; rate-limit state sweeps (rate × lifetime row) |
| 12 | mttp `schema` | JSON nesting (128); recursive codec depth (128); pattern compilation limits; union cases (1–64); form pairs |
| 13 | mttp `endpoint` + `endpoint/testkit`, with the `Body::Empty`-first fix and its regression test | endpoint body limit (1 MiB); query pairs (256); reported issues (100) |
| 14 | mttp `router`, `apispec`, `openapi` | path segments (64); OpenAPI traversal (128 edges, 100 000 nodes) |
| 15 | http-async `runtime` (+ VirtualClock), `conn` and socketconn, `codings` with `Decompress` and `compress` | decoder stages (5); decoded output per pull (64 KiB); codec windows; encoder output per pull (64 KiB); Accept-Encoding negotiation (16 KiB, 128 entries); VirtualClock `settle` rounds |
| 16 | http-async `backend` (native, wasm, js), socket integration tests, `examples/get` | JS upload buffer (16 MiB); JS delivery slices (64 KiB) and empty host chunks (1024) |
| 17 | http-async `server`, `fetch`, `hosts` with the Lambda empty-body fix (`undefined` when the event has no body); `examples/serve`, `examples/fetch` | fetch request body (1 MiB); fetch delivered chunks and empty-input budget; Lambda buffering (1 MiB / 4 MiB) |
| 18 | `mttp_digest`, `conformance`, `benchmarks`, the coverage ledger, `release.sh check` dry runs for all four modules | Digest challenge (16 KiB) and nonce origins (16) |

TEST_COVERAGE.md rows (uncovered lines with their reason) are added by each PR for its own packages; PR 18 closes the ledger with the full native coverage run.

### 7.2 Per-component decisions

| Component | Decision | Reason |
|---|---|---|
| model → http root | move | 68 tests and the WPT URL conformance suite pass on 4 targets |
| h1 codec | refactor | Strict syntax handling is right, but a tuple API does not suit a stable layer, and 13 tests are thin: add a smuggling and split-read conformance corpus |
| conn, clock, driver, sim family | move | Small, contracts already in CONTRACT.md; the intrinsics exist in 0.10.20 |
| internal/control | move | Pure, with property tests |
| h1client, h1server | refactor and **rewrite the tests** | The logic is mature, but most behaviour was checked only by socket tests (53 and 31) against 5 and 6 portable ones; move them onto sim + Driver so they run on 4 targets |
| mttp-net/h1, h1/client, h1/server, H1Backend duplicates, root facade, quick | delete | Duplicates, or replaced |
| mttp/client | refactor | Backend and SendOptions move to gaato/http |
| other mttp packages | move | Only the `@model` → `@http` import changes |
| endpoint | move + fix | Review finding: check `Empty` before reading (`endpoint/input.mbt`) |
| runtime (AsyncClock and the rest) | rewrite | Small, with a contract and 20 tests |
| VirtualClock | port | discord uses it at about 230 sites |
| TcpDialer, socketconn | rewrite | The old `@io.Reader`/`Writer` they used are gone in core/async |
| server listener | rewrite | 226 lines; keep its tests |
| codings | refactor + add the wrappers | Keep the 32 core tests |
| fetch, hosts | port + fix | Port to core's js_async; review finding: `hosts/lambda.mjs` must pass `undefined` when there is no body |
| mttp_digest | keep | — |

## 8. Migration and release

### 8.1 Consumer migration

Done inside the approved plan, in isolated migration worktrees (`/var/tmp/mttp-handoff-20261025/*-migration`); the consumers' own working copies are not touched.

| Consumer | Change |
|---|---|
| **mbt-sdk** | The generator targets `@http` (gaato/http 0.6) and `@client` (§4.12). openai, anthropic and github move; each SDK owns its vendor retry preset (`stainless` for openai and anthropic). sdk-runtime is retired. The `mbt-sdk/http` and `http-async` directories are removed once nothing uses them. |
| **codex-protocol** | `@sdkjson` → `gaato/mttp/jsonkit`. |
| **jsonrpc-async, codex-app-server** | Onto core/async; apply principle 9 if their APIs should survive (they expose `TaskGroup` and reader/writer types today). |
| **discord** | `ListenError`; `@server.serve` for the interactions listener; VirtualClock from http-async; the experimental opt-in for h1server/h1client users; `@http.Method` replaces moonbitlang/async's `RequestMethod`; see the table below. |
| **discord_voice, discord-cli** | Re-released on the new discord and core/async. |
| **kbbi, nekosama, profile-readme** | Onto mttp + http-async. |
| **requesto** | Last release: deprecation notice and a feature-by-feature migration map (without `quick`, which no longer exists). |

gaato/http 0.5 → gaato/http 0.6 + gaato/mttp:

| gaato/http 0.5 | Now |
|---|---|
| `Request{http_method : String, ..}` (mutable headers), `Response{.., body : Bytes}` | `@http.Request{meth : Method, ..}` (immutable headers, attributes), `@http.Response` with a pull `Body`; buffered reads through `@client.as_bytes()` |
| Url, UrlError, ipv6, utf8, percent/form/date helpers, `is_idempotent`, `append_query`, `retry_after_ms`, `parse_link_next` | `@http` (is_idempotent no longer trusts a header alone) |
| Body / StreamBody / BodyStream / TakenStream | `@http.Body` / `StreamBody` / `BodyStream` (take-once inside StreamBody) |
| Transport (send, send_stream), Middleware, send_with | `@http.Backend` (one send + SendOptions), wrappers, `@client.from_fn` |
| follow_redirects, RedirectHop, plan_redirect | `@client.FollowRedirects` + `RedirectConfig` |
| HttpError, RedirectError, Phase | `@http.TransportError(kind, phase, detail)` |
| clock, sync, random | `@rt` (same names, new trait identity) |
| mock.FakeClock / FakeTransport | `@sim.FakeClock` / `@testing.BackendStub` |
| cookie, multipart, retry, sse | `@cookie` + `@client/cookies`, `@multipart`, `@client/retry`, `@sse` + `as_sse` (all in mttp) |

gaato/http-async 0.5 → 0.6:

| 0.5 | 0.6 |
|---|---|
| AsyncTransport (send / send_stream) | `@backend.AsyncBackend` (one type for native, wasm and js) |
| DeadlineTransport | dropped: `timeout_ms` + Client `total_ms` |
| AsyncClock, ClockTimer, SemaphoreGate, with_timeout_opt; mock.VirtualClock, NoQuiescence | `@runtime`, same constructor forms |
| content_coding / content_decoder | `@codings` (+ `Decompress`, `compress`) |

gaato/sdk-runtime → gaato/mttp/client:

| sdk-runtime | mttp |
|---|---|
| `Client::new(transport, clock, base_url, default_headers, auth, retry, limiter, middleware, observer, random, timeouts)` | `@client.Client::new(backend, clock, base_url?, headers?, timeout_ms?, max_body_bytes?, read_idle_ms?, timer?, retry?, limiter?, total_ms?, observer?, random?)`; auth becomes a default header; middleware a Backend wrapper |
| `Timeouts{timer, attempt_ms, total_ms}` | `timer?`, `timeout_ms?`, `total_ms?` with the rules of §4.4 |
| send / send_json / send_stream; accept hook; body thunk | `RequestPlan::send` with `as_bytes` / `as_json` / `as_stream`; `ResponsePlan::map`/`map_ok`; `body_fn` |
| SdkError::Transport / Status / RateLimited / Decode / Config | `TransportError` (raised) / `ResponseFailure` values / `InvalidRequest` |
| RetryPolicy, RetryDecider, RetryContext; RateLimiter, WindowLimiter and friends; Paginator; json | `@client` (typed `decide_retry`), `@client/ratelimit`, `@client.Paginator` (Result-based), `@jsonkit` |

requesto 0.2 → mttp: `Response.url`/`history` from the `redirect_history` attribute; retries from the observer; Digest from `gaato/mttp_digest`; cookies from `client/cookies`; `steps`/`on_request`/`on_response` as Backend wrappers (they run per attempt) and the observer; MockTransport as BackendStub or Router-as-Backend; `sse(idle_timeout)` as `as_sse` + `read_idle_ms`; RequestoError as TransportError + ResponseFailure.

discord 0.13 → next:

| discord 0.13 | next |
|---|---|
| `http.Client(transport? : &@gaato/http.Transport)`; the sdk-runtime Client | `backend? : &@http.Backend`; `@client.Client` |
| `request_timeout_ms`, `max_connections`, `MAX_RESPONSE_BODY_BYTES` | Client `timeout_ms`; `ClientConfig.max_idle_per_origin`; Client `max_body_bytes` (+ the engine ceiling) |
| `DiscordHttpError::{Transport, Timeout}(phase~ : @gaato/http.Phase, ..)` | `phase~ : @http.Phase` (public break) |
| DiscordRetry over SdkError | a `decide_retry` function over `AttemptResult` |
| `REPLAY_SAFE_HEADER` + ClosedGate header stripping | `@http.replay_safe`; ClosedGate as a `from_fn` wrapper raising `Kind::Closed` |
| telemetry from `Attempt.body` | a per-call bounded excerpt recorded through an explicit private annotation |
| `pub using @ahttp {type RequestMethod}` | `@http.Method` |
| endpoint_http (stock parser) | a signed Endpoint served by `@server.serve` with discord's limits (1 MiB, 5 s, 5 s, 256) and `handler_timeout_ms = None` |
| JS facade and host adapters | `fetch_handler(handler)(req, background)` + the `hosts` shims |
| re-exported `ServerConfigError` with Bind | `ListenError`; qualified constructors rewritten |
| `@simclock.VirtualClock(..)`, `NoQuiescence` | `@runtime`, same constructor form |
| gateway websocket | discord's own, now on core/async |

### 8.2 Release train

**Every step below is an external operation and needs the owner's go-ahead at the time.** Nothing in §7.1 publishes.

1. Publish the four modules in one train: gaato/http 0.6.0, gaato/http-async 0.6.0, gaato/mttp 0.1.0, gaato/mttp_digest 0.1.0. Before that: resolver gate green, `release.sh check` dry runs green, and the SDK and discord migrations green against the candidates as workspace members.
2. Publish openai, anthropic and github in the same train or immediately after (flag-day rule, §5.8).
3. discord → discord_voice → discord-cli.
4. kbbi, nekosama, profile-readme.
5. requesto's last release.
6. `moon deprecate` sdk-runtime and requesto. Never gaato/http or http-async.

PR #2 is closed with a link to the stack when the stack is opened; its branch `ccr-eae554e2-r0xapl-u1` stays for reference.
## 9. Decision log

The log of 2026-10-24, with statuses updated by §0.1. Ids are kept so that §10, §11 and PR #2's history stay readable; the "Decision" column keeps its original wording, and the status says what replaced it.

| Id | Decision | Status | Rationale |
|---|---|---|---|
| M-01 | Modules: gaato/mttp (core only; incl. clock, clock/fake, jsonkit), gaato/mttp-net (all I/O), gaato/mttp-gen (tool, later). Existing gaato/http, http-async, sdk-runtime, requesto kept until Stage 6. | superseded: four modules, gaato/http 0.6 as the lower layer (§0.1, §3.1) | Module imports reach every consumer (F31); only external deps justify a module (R-12, S-02). |
| M-02 | clock and clock/fake are packages of gaato/mttp, with today's names and signatures. | superseded: the ports are `gaato/http/rt`, FakeClock is in `gaato/http/sim` (§3.2) | No non-HTTP consumer; consumers compile only imported packages (F18). |
| M-03 | jsonkit is `gaato/mttp/jsonkit`; alternatively it stays in mbt-sdk. | decided (§0) | Location only; the alias must not be `json`. |
| M-04 | mttp-net: backend, codings, runtime (v0.1); facade (v0.2); server, fetch (v0.3); files later; `internal/io`. No digest. Name mttp-net vs mttp-async. | superseded: `gaato/http-async` 0.6, no `quick` (§0.1, §3.3) | Digest's crypto dependency would reach every consumer; only requesto uses it (S-09). `internal/` keeps the bridges unimportable, as discord does. |
| M-05 | Runtime transition: signatures stay runtime-free; the switch is a flag day per application graph (Stage R), editing consumers' manifests. | decided: executed now on 0.10.20 (§0.1) | The runtimes cannot coexist (F35); async main/test needs the runtime in each consumer's manifest (F15, R-10). |
| M-06 | Exactly one facade at v0.2: requesto 0.3 (thin, no HTTP logic) or `mttp-net/quick` with requesto deprecated. | superseded: no facade (§0.1) | Neither has a consumer in the workspace (S-10). |
| M-07 | Digest and ChallengeAuth leave the core; requesto implements Digest itself if kept. | decided: Digest is `gaato/mttp_digest` | S-09. |
| M-08 | Monorepo with moon.work, plus the resolver gate, manifest-vs-index ledger, per-target test counts and paired-runtime mbti diff. | proposed | Workspace overrides hide real resolutions (F30). |
| M-09 | mttp ↔ mttp-net compatibility rule: option 1 (each mttp minor compiles the previous mttp-net minor) or option 2 (mttp-net patch per mttp minor). | resolved: mttp and http-async share only gaato/http (§0.1) | Lockstep cannot be enforced (F29, R-07). |
| M-10 | Reserve `gaato/mttp/v2` as the escape hatch. | decided; `gaato/http/v2` reserved too | Only a new path coexists (F28). |
| M-11 | Publish gate: mttp 0.1 and mttp-net 0.1 are published only after discord REST and openai pass against them as moon.work path members. | decided, extended to the four-module train (§8.2) | Under F28 every API fix found while porting would otherwise be a breaking 0.2. |
| E-01 | `TransportError(kind~, phase~, detail~)` with `#non_exhaustive Kind`; Int limits. | proposed | Extensible without breaking matches (F3); one integer type at every seam (I-14). |
| E-02 | `ResponseError` + `InvalidRequest`; SdkError dissolves; SDK signatures become open-raising. | superseded: `ResponseFailure` values; `InvalidRequest` kept (§4.4) | CM-12; sttp ResponseException. |
| E-03 | Declared errors: classify + per-variant codecs; same-status variants tried in order; no serve_result. | superseded: declared errors are `Result` values (§4.7) | Verified (SC-04); serve_result had no consumer (S-13). |
| C-01 | `Backend { send(Request, RequestOptions) -> Response raise TransportError; close }`; no WebSocketBackend. | superseded: `@http.Backend` with `SendOptions` (§4.2) | E4038 rules out polymorphic send (F1); WS deferred. |
| C-02 | Wrappers are Backend structs, or `from_fn`; no `layer`. | proposed | `layer` was one line over from_fn (S-04a). |
| C-03 | `ResponseAs{accept_head, reject, read, streaming}` with a public `ResponseAs::new`; `any_status`; buffered `from_head`; no `_always`/`as_either`. | superseded: ResponsePlan with modes and Result readers (§4.4) | Fixes call_with retries (I-03, verified); one mechanism (S-04b). |
| C-04 | Request shaping on `@model.Request`; opaque `ClientRequest[T]::new(raw, response_as)` with per-field option overrides and `ClientRequest::attribute`; no PartialRequest, RequestBuilder or WebSocketRequest. | proposed (overrides and `attribute` not in wf3/rev) | S-03, I-11, CM-02; endpoint calls must be markable as replay-safe or exempt. |
| C-05 | Placement rule: Backend wrapper / Client loop / Client defaults. | proposed | Unchanged principle. |
| C-06 | `client/retry` and `client/ratelimit` ported (substitution table in §4.4); `RetryDecider` over Error; `RetryContext::new` kept; presets keep today's method rules (`conservative`, `stainless`). | decided; vendor presets move to the SDKs (§4.4) | I-12, CM-15; both packages name `@http.Headers`/`@sync.Gate`/`HttpError` today. |
| C-07 | Rate limiter kept; the bucket comes only from the `rate_limit_bucket` attribute, set by the facade or by `Endpoint::rate_limit_bucket(f)`, never from the operation id; release uses the head's status and headers once a head is known. | proposed | S-04d, S-12 (verified); GitHub and discord bucket by method, URL and route. |
| C-08 | One attempt deadline (`timeout_ms`), the `body_deadline` flag, `read_idle_ms`; Client `total_ms` shrinks it; no attempt starts after the total; non-positive limits fail at once; Timer only as fallback. | superseded: `BodyTiming` + Client defaults; a total deadline requires a Timer (§4.4) | RT-07, S-04c, CM-09; sdk-runtime's `check_deadline` and `retry_timeouts_test.mbt`; flag and fallback verified. |
| C-09 | Typed attributes on Request **and** Response, from v0.1. | proposed | replay_safe, operation_id (v0.1), remote_addr, background, route_template (v0.3); adding the field later would break literals (E4044). |
| C-10 | `Client` (backend + defaults + policy) is the only sending path; base URLs joined by prefix. | proposed | sdk-runtime's shape (S-03); RFC 3986 resolve drops /v1 (CM-01, verified). |
| C-11 | Client-wide `options : RequestOptions` on `Client::new` (v0.1); AsyncBackend keeps `max_body_bytes` as a hard ceiling. | superseded: Client `timeout_ms`/`max_body_bytes`/`read_idle_ms`; the engine keeps `ClientConfig.max_body_bytes` as a ceiling | discord, openai, anthropic and github all set client-wide timeouts or body caps. |
| C-12 | The loop enforces only replayability (a `Wait` on an unreplayable request becomes `Stop(NotReplayable)`); method gating is the decider's. `Body::Stream` keeps the take-once guard. | decided (implemented in PR #2) | `stainless` resends POST today; CONTRACT 8. |
| C-13 | `decompress`: true sends the full Accept-Encoding when the request has none and decodes; a request's own Accept-Encoding passes through; false sends the request's value or `identity`. | superseded: `@codings.Decompress` wrapper (§4.11) | Keeps http-async's behaviour; F40. |
| X-01 | `Request.url : String` (absolute or relative; parsed at send). | decided (§0) | Generated code stays non-raising; a read-only `Url` field forces E4036 or new raises (CM-02, S-11). |
| X-02 | Int status; `#non_exhaustive Method` with Show; immutable ordered Headers. | proposed | I-13, S-05. |
| X-03 | UriBuilder/UriPart/Trusted at v0.2; `uri()` returns String (no raise). | proposed | No v0.1 consumer (S-11). |
| X-04 | Pull-only bodies in both directions; one `Response` type; `#non_exhaustive Body`. | proposed | S-04e/f; verified. |
| X-05 | Server SSE as pull `EventStream` → `Body::Stream`; no push bridge. | proposed | Replaces the old needs-prototype item; verified through Router-as-Backend. |
| X-06 | WebSockets deferred beyond v0.4; later order: sans-IO `mttp/ws` codec with bounds (+ Autobahn), client over `@http.Client` passthrough, server via the h1 101 hand-off, `WsEndpoint` last. | decided (§0.2) | No consumer (S-08). The runtime client can send request headers on native/wasm; the real gaps are listed in §0. |
| X-07 | Evolution rules (§5.6): `#non_exhaustive` on every enum that may grow (incl. AuthScheme, Location, Framing, FailureStage, Decision); a growing suberror takes the kind form (DecodeFailure, ParseError), all other suberrors frozen; frozen-struct lists per tier; Atom/VariantDoc/EndpointDoc read-only with constructors. | proposed | S-05; F3, F4, F52. |
| X-08 | `impl Eq` (Stream by identity) and `Debug` for `Body`. | proposed | The moved multipart `Part` derives Eq and Debug over its body. |
| P-01 | Input = atoms + staged closures; `Input::new` public with `Staged::ready`/`after_body`, an opaque `RequestSink` with setters, and `Atom::new`; `attribute(key)` input; client_ip/query_params/headers at v0.3. | proposed (Input::new usable outside endpoint: not yet verified) | SC-07; attribute input verified; in wf3/rev `Input::new` fails outside the package (E4015, E4094). |
| P-02 | Set-once builders, with the Unit-slot and base-capture limits documented. | proposed | I-07, I-08. |
| P-03 | OpenAPI templates + typed path inputs; `{name...}` rest capture decided before freeze. | needs-prototype | SC-09. |
| P-04 | Credentials-first server ordering (documented deviation). | decided (§0) | Verified behaviour; may surprise tapir users. |
| P-05 | 400 vs 422 for invalid bodies. | decided (§0) | — |
| P-06 | Router: trie, literal beats capture, 404/405/HEAD/OPTIONS, no fall-through. | proposed | Verified. |
| P-07 | Middleware over Response; `route_template` response attribute; `on_unhandled -> Response?`; decode_failure/reject hooks; FailureContext and DispatchContext in endpoint. | proposed | I-01, SC-06; verified. |
| P-08 | Client interpreter on `Client`: selection by (status, media type); reject inside the attempt; relative targets; sync half internal. | proposed | I-02, I-03, I-04, S-07; verified. |
| P-09 | Router-as-Backend isolates attributes; `testkit.when_endpoint` with async raising respond; one checker. | proposed | I-09, I-10, SC-17, S-04g; verified. |
| P-10 | Schema with `defs`/`$ref`, `recursive`, `tagged`, objectN up to 8; ECMA `pattern` translator. | proposed (translator needs-prototype) | SC-01, SC-11 verified; SC-02. |
| P-11 | apispec/openapi at v0.4; merge rules; AND security; signatures as header parameters; OpenAPI 3.1 only. | proposed (version decided in §0.1) | I-15, SC-04, SC-05; verified. |
| P-12 | Codegen: tools/gen (Python) phase 1 now; mttp-gen dropped until a consumer exists. | proposed | S-07, R-11. |
| P-13 | Header outputs (`and_header`, `fixed_header`); `and_status`, `set_cookie` at v0.3; WWW-Authenticate on declared 401s. | proposed | SC-03, CM-13; header output verified. |
| T-01 | `run_sync` in one file; its package allows `unused_async`. | decided: `run_sync` lives in `gaato/http/driver` (§4.10) | S-14; verified. |
| T-02 | Conformance: corpora, ledgers, the cross-layer e2e gate, per-target test counts. | proposed | I-16, RT-15, R-08. |
| T-03 | FakeClock in mttp/clock/fake; VirtualClock in mttp-net/runtime. | superseded: FakeClock in `gaato/http/sim`, VirtualClock in `http-async/runtime` | — |
| T-04 | `testing` (model + client only) separate from `endpoint/testkit`. | decided; contract checkers move to `gaato/http/sim` (§4.1) | S-06. |
| T-05 | `moon check --deny-warn` on all 4 targets with both toolchains is a Stage 0 exit criterion and a CI gate. | decided; one pinned toolchain (0.10.20) | wf3/rev has 84 warnings today (F53). |
| B-01 | Bounds as in §5.2. | proposed | — |
| B-02 | A sans-IO HTTP/1.1 codec (`gaato/mttp/h1`) replaces the stock server parsers: version, 100-continue, chunked decoder reporting end, trailers and consumed bytes; later also used by AsyncBackend for responses. | decided: `gaato/http/h1`, used by both engines (§4.5) | RT-04, RT-06, RT-13; RESOURCE_BOUNDS client-side known gap. |
| B-03 | Server body limit = `min(adapter ceiling, endpoint override or router default)`; both adapter ceilings 1 MiB; an override above a known ceiling is an advisory definition problem. | proposed | Four knobs without a stated precedence. |
| A-01 | Runtime-free adapter API: serve (+ Bind/Accept, ServeError); host-neutral `fetch_handler(handler)(req, background)` with JS shims per host; `pub fn fetch`. | decided; `ServeError` → `TransportError`, Bind/Accept → `ListenError` (§4.11) | RT-01, RT-08, RT-09, RT-12, CM-05; discord supports six JS hosts, and Fastly needs `waitUntil` synchronously. |
| A-02 | Bounded content decoding; Accept-Encoding per C-13. | proposed | RT-16. |
| A-03 | mttp-net/server never ships without `h1`. Until discord's endpoint_http adopts `h1`, it sits behind a header-limiting proxy, and discord's README says so. | decided: the server engine parses only with `h1` | RT-05; F36–F38 apply to endpoint_http today. |
| G-01 | SDK phases: phase 1 mechanical retarget (§4.12); phase 2 opt-in after v0.3/v0.4. | proposed | CM-02, CM-04. |
| G-02 | No forward shim. Default (d): clocks are new traits and mixed graphs pass two clocks. Optional gaato/http 0.5.1 `bridge` package for mixed graphs. Alternative (a): `mttp/clock` re-exports gaato/http 0.5.0's traits until a later minor. | decided (§0) | A forward 0.5.1 shim is inert unless something requires it (F33). |
| G-03 | discord 0.14 as in §8.6 (including the DiscordHttpError phase type and the client options); interactions server onto `h1` at Stage 3 (Q9 (c)) or Stage 4. | superseded: discord moves once, onto the new stack and core/async together (§8.1) | CM-05, CM-06, CM-10. |
| G-04 | Retirement by advisory deprecation; no yanks; security via patches plus raised minimums. | proposed | F26, F27. |
| G-05 | Stage R train list (§8.1), including discord-cli and kbbi if migrated. | superseded: Stage R happens with the rebuild (§0.1) | RT-03, CM-10; registry index. |
| G-06 | Old-stack graphs at Stage R: (a) an http-async 0.5.x patch on core async, or (b) frozen pre-R. | decided: (b), old-stack graphs frozen (§5.8) | F35; http-async's API names no runtime type; F26. |
| G-07 | Published consumers kbbi and discord-cli join the plan; kbbi migrates or stays on the 0.4 stack. | decided: both migrate (§8.1) | Registry index: kbbi 0.1.6 and discord-cli 0.1.8. |
| G-08 | discord breaks twice (0.14 at Stage 2, again at Stage R) rather than once. | resolved: discord breaks once (§8.1) | The REST move need not wait on a toolchain. |
| N-01 | Naming rules (§5.9). | proposed | — |
| N-02 | Adapters set `remote_addr` and `background`; the Workers shim also sets `env`; handlers read them through `attribute`. | proposed | SC-07, RT-08. |
| N-03 | HTTP/1.1 only; TLS and HTTP/2 via a front proxy. | decided: HTTP/1.1 only (no ALPN in core/tls) | — |
| V-01 | Staged tiers v0.1 → v0.4 (§7). | superseded: all tiers in mttp 0.1; review order by the PR stack (§7) | S-01, S-07. |

## 10. Verified facts and refuted assumptions

F1–F64 were verified in October 2026, before core/async shipped, and use the package names of that time (`mttp-net`, `@model`, `@clock`). They are kept as the record behind the decisions; F65–F68 were added for the rebuild. "4×2" means wasm-gc, js, native and wasm, each with moonc 0.10.16+b1a0e846e and 0.10.17+d971670cd. Paths are relative to the scratchpad directory given at the top.

### 10.1 Verified facts

| # | Fact | How verified | Where |
|---|---|---|---|
| F1 | A trait with a polymorphic method cannot be a trait object (E4038). | compile probes (first workflow) | wf1 designs D1, D3 |
| F2 | A suberror cannot take type parameters. | parse error | D1, D4 |
| F3 | `#non_exhaustive` is enforced on enums across packages (a catch-all is required). It is ignored on suberrors and on structs (warning 0043); see F52 for the consequence. | 0.10.16 and 0.10.17 | `wf2/scope/e2`, `e2b` |
| F4 | Adding a field to a `pub(all)` struct breaks downstream literals (E4044); record updates keep compiling. A read-only `pub` struct cannot be built or record-updated outside its package (E4036). | 0.10.16 and 0.10.17 | `wf2/scope/e2`, `wf2/sigprobe/src/b/b.mbt` |
| F5 | `in` is a keyword; `method` warns on 0.10.17; `pub fn ignore` breaks the generated test driver; duplicate package aliases warn. | compile probes | D1, D2 |
| F6 | Arrow lambdas type-check against async function types, including closed `raise TransportError`. They cannot take an `async` prefix. An `async fn` literal implies open raise (E4118 where closed is expected) and warns `unused_async` if it never awaits. | 4×2 | `wf2/integration` (I-17), `wf3/rev` |
| F7 | `E::_` downcast in a generic function is E4225; a concrete `ApiError::_ as a` works. | compile probe | D2; `wf3/rev/app/src/api/api.mbt` |
| F8 | Methods on a specialised self type give set-once builders. Set-once is not enforced while the slot's type is `Unit`. | 4×2 | `wf2/integration/app/src/e2e/findings_test.mbt`, `wf3/rev` |
| F9 | A named closed-raise function is rejected where an open-raise function type is expected (E4014). | 0.10.16 and 0.10.17 | `wf2/consumer-migration/negatives/raise_subtype` |
| F10 | `pub using` re-exports across modules preserve trait identity through registry resolution and execution, 4×2, but only when the shim version is the one selected. Qualified constructors through a `pub using` type re-export fail (E4021). | fake registry; 4×2 | `wf2/resolver/g2d`, `g2e`, `g2h`; `wf2/consumer-migration/jsonkit-shim` |
| F11 | Outside the defining package, unqualified constructors in open-raise contexts are unbound (E4021) and `catch` over `Error` cannot resolve them (E4029). | 4×2 | `wf2/integration` (I-06) |
| F12 | Unused top-level `pub let` values are removed in release builds. | wasm-gc size probe | first workflow, feasibility judge |
| F13 | `try?` is removed in 0.10.17. Both toolchains deprecate `Map::new()`, `.to_json()` on literals, `StringView::to_string`, Show-for-debugging and `to_array`. | compile output | `wf3/rev` (`moon check`) |
| F14 | `Method` without a Show impl cannot be interpolated (E4018). | 0.10.16 and 0.10.17 | I-13; `wf3/rev/mttp/src/model/model_test.mbt` |
| F15 | `async fn main` needs moonbitlang/async imported by the consumer (E4037). moon 0.1.20261023 generates `async test` drivers calling `@moonbitlang/core/async.run_async_main` (E4020 without it). A plain `test` driving async code through `%async.run` + `%async.capture_cancellation` works on all 4 targets. | 0.10.16 and 0.10.17 | `wf2/resolver/c4`, `c6`, `c7`, `c8`; `wf3/rev/mttp/src/testing/run_sync.mbt` |
| F16 | On wasm-gc, `async test`s are silently skipped ("Total tests: 0", or a deliberately failing one counted as passed). | both toolchains; core-main | `wf2/resolver/rootonly`; `wf2/runtime/core/async/zz_mttp_model/async_probe_wbtest.mbt` |
| F17 | An unrestricted package importing a target-restricted one breaks whole-module checks for other targets. Scoped (`-p`) checks and consumers that import only unaffected packages still work; declaring `supported_targets` on the importer fixes it. | 0.10.16 and 0.10.17 | `wf2/resolver/t4a`, `c3`, `c10`, `c11` |
| F18 | A consumer compiles only the packages it imports from a dependency, plus their transitive imports. | `moon build --dry-run` | `wf2/scope/e1`, `e1b` |
| F19 | A per-package `warnings = "-unused_async"` in moon.pkg makes the run_sync intrinsics pass `--deny-warn`. This covers the run_sync file only; `wf3/rev` as a whole does not pass (F53). | 0.10.16 and 0.10.17 | `wf3/warnprobe` |
| F20 | A JS `pub let fetch = ...` is not exported (the module exports only `default`); a `pub fn fetch(req)` wrapper is. | Node 22, both toolchains | `wf2/runtime/v0225/src/worker`, `wf2/runtime/run_worker.mjs` |
| F21 | `derive(ToJson)` cannot emit `{"type": tag, ...fields}`; `repr(tag=..)` alone is silently ignored. A hand combinator `tagged` round-trips and documents oneOf + discriminator. | 4×2 | `wf2/completeness/schema/src/derive`, `schema/src/fix/union.mbt` |
| F22 | `@string.Regex` (lexmatch) rejects ECMA-262 patterns from the SDK specs (`^[a-zA-Z0-9_-]{1,64}$`, `\d`, `\w`). | 4×2 | `wf2/completeness/regex/src/re/re_test.mbt` |
| F23 | RFC 3986 `resolve` drops the base path ("https://api.openai.com/v1" + "/chat" → "https://api.openai.com/chat"); prefix join keeps it. | 4×2 | `wf2/consumer-migration/urlres`; `wf3/rev/mttp/src/model/model_test.mbt` |
| F24 | String ordering in MoonBit is length-first (affects sorted-key assertions). | test output | `wf3/rev` openapi test |
| F25 | `apispec` derive renames (`in`, `type`, `$ref`) round-trip; None fields are omitted. | 0.10.16 and 0.10.17 | `wf2/scope/e3`, `wf3/rev` |
| F26 | moon's MVS selects the highest *declared minimum* per module, not the newest published version. A root requiring gaato/http@0.1.0 resolves 0.1.0 although 0.1.1–0.5.0 exist. | fake registry; e1 re-run for this draft | `wf2/resolver/e1`, `e5c` |
| F27 | `moon deprecate` applies to all versions of a module, is advisory, does not affect selection, and later versions start undeprecated. `--deny-warn` still passes with a deprecated dependency. The registry index stores a deprecation as `yanked: true` plus `yanked_reason` on each version existing at that time; across the whole index, one module has mixed values, and only because a later version was published (moonbit-community ffi 0.2.1–0.2.5 yanked, 0.2.6 not). | `moon deprecate --help` on both toolchains (re-run); fake registry; scan of `~/.moon/registry/index` for this draft | `wf2/resolver/e5a`, `e5b` |
| F28 | 0.x and 1.x are one compatibility set; 1.0.0 and 2.0.0 on one path is a hard error; `lib` and `lib/v2` coexist. | fake registry | `wf2/resolver/e4b`, `e4h`, `e4c` |
| F29 | moon.mod accepts only plain `X.Y.Z` (no `=`, `~`, `^`, `<`, or `0.1`). An app requiring net@0.1.0 plus an SDK requiring core@0.2.0 builds old net against new core and fails (E4021). | fake registry | `wf2/resolver/vq1`–`vq5`, `s1` |
| F30 | A moon.work member silently overrides a lower requirement and only warns on a higher one. mbt-sdk's local manifests already differ from the registry entries of the same versions. So does discord.mbt: the local discord_voice 0.3.1 imports discord 0.13.0, gaato/http 0.5.0 and http-async 0.5.0, while the registry's 0.3.1 requires discord 0.12.0, gaato/http 0.4.1 and http-async 0.4.2. | both toolchains; index grep (discord_voice re-checked for this draft) | `wf2/resolver/ws1`; `discord.mbt/discord_voice/moon.mod`; `~/.moon/registry/index/user/gaato/discord_voice.index` |
| F31 | A module-level import reaches every consumer's download set and version selection (a consumer of only net/codings on wasm-gc still downloads moonbitlang/async and is lifted 0.22.0 → 0.22.5). Packages of a transitive module cannot be imported. | fake registry | `wf2/resolver/c1`, `c5`, `c9` |
| F32 | Split, independently versioned modules isolate consumers' versions; a merged module does not. | fake registry | `wf2/resolver/fake/split` (`s2`, `s3`) |
| F33 | A forward shim (gaato/http 0.5.1 re-exporting new traits) is inert unless something requires 0.5.1 (7 trait errors). It works when the app requires it. A reverse shim (new module re-exporting the old traits) works with no release. | fake registry; 4×2 | `wf2/resolver/g2a`, `g2c`, `g2d`, `g2e`, `g2g` |
| F34 | Adapter public APIs (AsyncBackend, serve, ServerLimits, ServerConfigError, fetch_handler) built on moonbitlang/async 0.22.5 and on core-main async produce identical mbti files apart from the package line. Tests pass on native, wasm and js. | moon info diff; 0.10.17 (+ 0.10.16 for 0.22.5) | `wf2/runtime/v0225/src/net`, `wf2/runtime/core/async/zz_mttp_net`, `wf2/runtime/shared/fetch` |
| F35 | moonbitlang/async 0.22.5 and the toolchain runtime cannot coexist in one native process: both define a non-static global `pool` (duplicate symbol at link). Nested loops block each other, and cross-runtime calls abort (SIGABRT) or panic on JS. | link and run (runtime review); source check for this draft: both `thread_pool.c` files (toolchain `lib/runtime` of 0.10.16 and 0.10.17, and async 0.22.5) define a global `} pool;` | `wf2/runtime/core/async_coexist`, `wf2/runtime/old_syms.txt` |
| F36 | Both stock server parsers grow memory without bound on a long header or chunk-size line (≈29–37 MiB in 5 s) with quadratic ingest (16 MiB line: ≈21–23 s). A bounded pre-scan or own codec holds 16–108 KiB. Pre-scan in front of the stock parser is possible only on core-main (`Tcp.peek_at_least`). An own-codec loop on raw Tcp works on 0.22.5 today: re-run for this draft, it answered an oversize head with 431, reset a 5 s header-line flood after 320 KiB with no measurable RSS growth (stock: +35 MiB), and passed 6/6 tests on native. | RSS/time tests; 0.22.5 re-run on moon 0.1.20261023 | `wf2/runtime/core/async/zz_mttp_net/net_test.mbt`, `wf2/runtime/v0225/src/net` (`serve_conn_own_codec`) |
| F37 | The 5 s header timeout bounds time, not bytes: 32 flooding connections reached ≈129 MiB accepted and +52 MiB peak RSS; with a pre-scan, 16 KiB per connection, 431 and close. | net test | same |
| F38 | Stock servers serve a smuggled request after Content-Length + Transfer-Encoding (two responses on one connection) on both runtimes. | net test | same (`*CL+TE*`) |
| F39 | The runtime `send_response` merges duplicate response headers, and both stock parsers merge duplicate request headers. Raw writes keep duplicate Set-Cookie. | round trips | same |
| F40 | Core's client auto-gunzips only when no Accept-Encoding is sent, and raises NotImplemented for br/zstd and for any transfer coding other than chunked. The JS client buffers request bodies. | source reading + backend prototype | `send.mbt`, `parser.mbt`, `client.js.mbt` in both runtimes |
| F41 | core-main async builds and tests with today's toolchain from a core checkout (http 63/63 native, js_async 13/13 js on 0.10.17). | moon test | `wf2/runtime/core` |
| F42 | core-main vs 0.22.5: io.Reader/Writer → BinaryReader/BinaryWriter; `&@io.Data` removed (writes take BytesView); `read_until` takes and returns bytes; `drop` → `drop_all`/`drop_exactly`; URIParseError → UriParseError; http get/post/put take `*_binary`/`_text`/`_json`; `Client(verify?)` removed; `@fs.read_file` removed; CondVar alias, `is_cancellation_error`, `with_cancellation_handler` removed; `set_external_event_loop` native-only; `return_immediately()` takes no value; `Tls::server` takes optional files + pfx; TaskGroup non-generic. Duplicate-header merging is the same in both. | mbti diff | `wf2/runtime` (RT-14) |
| F43 | moonbitlang/core has no crypto; requesto's Digest uses moonbitlang/x. | source | first workflow |
| F44 | **Revised design end to end**: 31/31 tests, 4×2. Covered: definition package on wasm-gc; `Endpoint::call` through `Client` → Router-as-Backend → serve; declared errors as the user's type; two same-status variants; 400 listing every problem; 401 before body read; 404/405/HEAD/OPTIONS; framework 404 vs declared 404; 413 + close, 415, 201 + Location header output; signed webhook with raw_body; retry with FakeClock and observer bucket; call_with retried on 503; unbuffered SSE pull through the router and refusal over a buffered limit; attribute isolation and `remote_addr`; `route_template` for middleware; `when_endpoint` with a declared error; OpenAPI merge (two media types, oneOf, nested and recursive `$ref`, header docs, signature as parameter); one checker; GraphQL-in-200 retry with prefix base URL, default-header precedence and release with the 200's head; `body_deadline` flag; Timer fallback; `replay_safe`; `join_url`; Method Show. Not covered: the `total_ms` deadline rules, `body_fn`, replayability enforcement in the loop, limiter waits under `total_ms`, the real `client/retry` port (`wf3/rev` uses a stand-in rule), Client-wide options, the take-once stream cell, `Input::new` from another package. Re-run on a copy with the F54 edit (`v4/rev`, 0.10.17): 31/31 on wasm-gc, js, native and wasm. | `moon test` on all 8 combinations | `wf3/rev` |
| F45 | First integration prototype: 27/27 on 4 targets (re-run on 0.10.17), including Push buffering and the findings later fixed in F44. | re-run | `wf2/integration` |
| F46 | A v0.1-sized client (one ClientRequest + a Client bundle) passes the GraphQL retry scenario. The endpoint layer adds on top of unchanged v0.1 model and client. | re-run (0.10.16, wasm-gc and native) | `wf2/scope/v01` |
| F47 | Real consumer ports on the proposed client compile and pass 4×2: discord REST (DiscordRetry, ClosedGate, 429 body telemetry, replay-safe attribute), GitHub (GraphQL in 200, Link paginator as `Paginator[T, Error]`), OpenAI SSE with a `[DONE]` sentinel (429 head retried, body read once). | 4×2 | `wf2/consumer-migration/cm/src/{discord_rest,github,openai_stream}` |
| F48 | Output headers, dynamic status and `one_of_body` with 406 round-trip. | 4×2 | `wf2/completeness/out/src/o` |
| F49 | A Backend → gaato/http 0.5.0 Transport bridge works (buffered) on 4 targets. | 4 targets | `wf2/consumer-migration/bridge` |
| F50 | Staged decoding gives security before body: 401 after zero body reads, 401 outranks 400, and `raw_body` in a security input lets a signed webhook check the raw bytes. | 4×2 | D4 runner; `wf3/rev` |
| F51 | moon 0.1.20261023 no longer supports `bin-deps` in moon.mod; moon.mod has no dev or optional imports; `moonx` lists only the wasm target. moonbitlang/parser 0.4.6 depends on moonbitlang/async 0.22.4, moonbitlang/x 0.5.1, lexer, moon_config and prettyprinter. | binary strings, `moonx --help`, registry index | R-11 (`wf2/resolver`) |
| F52 | `#non_exhaustive pub(all) suberror E {A; B}` gives warning 0043, and a downstream exhaustive `catch { A => ..; B => .. }` over `raise E` compiles. Adding a constructor `C` then breaks that downstream function (partial match: the uncaught case makes a non-raising function raise). | 0.10.17 compile, before and after adding `C` | `crit/ne` (critic's probe), `v4/ne` (with `C`) |
| F53 | `moon check --target wasm-gc` on `wf3/rev` reports 84 warnings (48 deprecated, 21 unused_async, 15 unused_package), so `--deny-warn` fails. unused_async fires in seven library files (`client/response_as.mbt:73`, `endpoint/output.mbt:238` and `:343`, `endpoint/server.mbt:245`, `endpoint/testkit/testkit.mbt:24`, `openapi/openapi.mbt:144`, `testing/run_sync.mbt:21`), besides the app and tests; `testing/moon.pkg` sets no `-unused_async`. | 0.10.17 (the critic reports the same counts on 0.10.16) | `v4/rev`, a copy of `wf3/rev` |
| F54 | Writing the e2e server's `authenticate` and handlers as arrow lambdas (`let auth : async (String) -> String = token => ..`, `serve(auth, (_who, q) => {..})`) compiles, removes every warning from `app/src/e2e/app.mbt`, and keeps 31/31 on wasm-gc, js, native and wasm. | 0.10.17 | `v4/rev/app/src/e2e/app.mbt` |
| F55 | In `wf3/rev`, `Staged[T]` is `pub` with private fields and no constructor, and `RequestSink` is a read-only `pub` struct with `mut` fields, so `Input::new` cannot be used outside `endpoint` (E4015 "has no method ready", E4094 "Cannot modify a read-only field"). | mbti inspection; the critic's cross-package compile | `wf3/rev/mttp/src/endpoint/pkg.generated.mbti` |
| F56 | The registry index lists two published gaato consumers that are not in /home/user: `gaato/kbbi` 0.1.6 (gaato/http 0.4.0, http-async 0.4.1, moonbitlang/async 0.22.5) and `gaato/discord-cli` 0.1.8 (discord 0.13.0, moonbitlang/async 0.22.5). `gaato/req` 0.1.0 is already deprecated ("Renamed to gaato/requesto"). | index read | `~/.moon/registry/index/user/gaato/*.index` |
| F57 | http-async's public API names no runtime type: the mbti of `gaato/http-async` imports only gaato/http, http/clock and http/sync, and `mock` imports only http/clock and core debug. | mbti read | `mbt-sdk/http-async/src/**/pkg.generated.mbti` |
| F58 | `RetryPolicy::stainless` retries 408/409/429/5xx with `methods: Any` and `sent_failures: Any`; `conservative` retries 429 for any method but 408/409/500/502–504 and sent failures only for idempotent requests. openai and anthropic default to `stainless`. `StopReason::NotReplayable` exists, and `@retry.Decision` is not `#non_exhaustive`. | source read | `mbt-sdk/sdk-runtime/src/retry.mbt`; `http/src/retry/pkg.generated.mbti`; `openai/src/client.mbt:56`, `anthropic/src/client.mbt:63` |
| F59 | sdk-runtime raises `Timeout(phase=Unknown, ms=total_ms)` before an attempt once the total deadline has passed, without asking the decider or calling the observer; non-positive limits fail at once; `remaining_ms` reaches the decider. runtime-tests pins this in three tests. | source read | `sdk-runtime/src/client.mbt` (`Timeouts` doc, `check_deadline`); `runtime-tests/src/retry_timeouts_test.mbt:64,131,186` |
| F60 | discord's `RequestMethod` is moonbitlang/async/http's type (`pub using @ahttp {type RequestMethod}`); gaato/http has none. discord/http also uses `@async.with_task_group`, `is_being_cancelled` and `pause`. | source read | `discord/src/http/route.mbt:3`, `moon.pkg`, `request.mbt`, `handles_channel.mbt` |
| F61 | discord's JS interactions run on six hosts through `handleInteraction(request, config, scheduleBackground)` / `handleRawInteraction`: Workers, Fastly (`event.waitUntil` registered synchronously before `respondWith`), Vercel (`waitUntil` from `@vercel/functions`), Deno and Bun (`trackBackground`), and Lambda URLs (no Web Request; awaits the background before replying). | source read | `discord.mbt/examples/{interactions_js,workers_echo,fastly_echo,vercel_echo,deno_echo,bun_echo,lambda_url_echo}` |
| F62 | tools/gen never emits `SdkError::Config`; generated multipart operations raise `@multipart.MultipartError` and take `boundary : String`; GET/POST/PUT/PATCH/DELETE use builders and anything else `@http.Request::new("X", ..)` (no SDK hits that branch; GitHub has 74 `Request::patch` calls). `Config` is raised by hand-written facade encoders. | source read, grep | `tools/gen/emit_moonbit.py:703,730,754–758,845`; `openai/src/encode.mbt` |
| F63 | The client side of the runtime reads response heads, chunk-size lines, trailers and a proxy's CONNECT answer with an unbounded `read_until`. | RESOURCE_BOUNDS known-gaps row | `mbt-sdk/RESOURCE_BOUNDS.md` ("Known gaps") |
| F64 | github.com/gaato/mttp exists with no commits (`/home/user/mttp`, origin `https://github.com/gaato/mttp`). `mbt-sdk/conformance` holds cookie, sse, url, harness and jsonrpc corpora and imports gaato/http 0.5.0 and jsonrpc. | git, ls | `/home/user/mttp`, `/home/user/mbt-sdk/conformance` |
| F65 | `moonbitlang/core/async/http` on 0.10.20 bounds neither the size of a response or request head, accepts a message with both Content-Length and Transfer-Encoding, decodes only gzip, and its connection reuse is still provisional. | source reading during the rebuild planning (2026-11-08) | `moonbitlang/core` 0.10.20, `async/http` |
| F66 | MoonBit 0.10.20 (moonc dated 2026-11-05) ships `moonbitlang/core/async`. Its packages declare `options(experimental: true, ..)`, so importers must opt in with `allow-experimental-packages`. The `%async` intrinsics the Driver uses are still present (core keeps its own in `async/internal/coroutine/async_primitive.mbt`). | `moon version --all`; core sources | `moon version --all` = 0.10.20+65efd5b93; `~/.moon/lib/core/async/*/moon.pkg` |
| F67 | core/async's socket and TLS APIs have no write-half shutdown, and core/tls has no ALPN. | source reading during the rebuild planning | `moonbitlang/core` 0.10.20, `async/socket`, `async/tls` |
| F68 | PR #2's engines are mature but mostly socket-tested: h1client 53 socket tests vs 5 portable, h1server 31 vs 6; the h1 codec has 13 tests; model 68 tests plus WPT URL conformance; codings 32 core tests; runtime 20 tests. | test counts on the reference branch | `ccr-eae554e2-r0xapl-u1` (1ea1b3b) |

### 10.2 Refuted or corrected assumptions of the first architecture

| Assumption | Finding | Evidence |
|---|---|---|
| "MVS: the highest wins" | the highest *required* minimum wins; patches do not propagate | F26 (R-01) |
| "A yanked version still resolves; deprecate ≈ yank" | there is no yank; deprecation is module-wide and advisory | F27 (R-04) |
| "gaato/http 0.5.1 shim makes discord 0.13, sdk-runtime 0.7 and http-async 0.5 interoperate" | inert unless required; only the clock traits would be shared anyway | F33 (R-02, CM-11) |
| "mttp and mttp-net in lockstep minors" | not enforceable; old net plus new core resolves | F29 (R-07) |
| "A module split gives no 0.x isolation" | it does when the parts are versioned independently | F32 (R-06) |
| "Target isolation is a module reason" | per-package `supported_targets` suffices | F17 (R-08) |
| "gaato/clock and gaato/jsonkit must be modules" | no non-HTTP consumer; packages compile individually | F18 (R-12, S-02) |
| "Runtime-free signatures mean the runtime switch does not change consumers" | consumers' manifests change; two loops cannot coexist | F15, F31, F35 (R-10, RT-02) |
| "Stage 4 touches mttp-net and discord's gateway; jsonrpc-async is untouched" | jsonrpc-async, codex-app-server and discord_voice expose runtime types | RT-03, CM-10 |
| "A head reader in front of the runtime parser enforces 431 and bounded chunk lines" | only on core-main, never for chunk lines | F36 (RT-04) |
| "Until B-02, slowloris protection rests on the header timeout" | the timeout bounds time, not bytes | F37 (RT-05) |
| "The runtime parser is safe enough for request framing" | CL+TE smuggling | F38 (RT-06) |
| "discord endpoint_http cancels a handler on disconnect" | it does not; this is new behaviour | RT-11 |
| "Core-main merges duplicate server headers (unlike 0.22.5)" | both merge | F39, F42 (RT-14) |
| "`fetch_handler(handler)` replaces discord's Workers facade" | needs a background channel (waitUntil or its equivalent per host), env on Workers, and the abort signal | RT-08, CM-05, F61 |
| "`pub let fetch = fetch_handler(..)` exports fetch" | not exported | F20 (RT-09) |
| "`RequestOptions.timeout_ms` covers the head or the whole body" | the backend cannot tell which without a flag | RT-07 |
| "FailureContext/ServerOptions.decode_failure in router" | import loop; they must live in endpoint | I-01 |
| "The client picks the variant by status" | a framework 404 becomes Deserialization; same-status variants are unreachable | I-02, SC-04 |
| "A static ReadMode gives call_with the same retry semantics" | call_with was never retried on 503 | I-03 |
| "encode_request(base : Url, ..) works over the model Url" | E4036; resolve drops the base path | I-04, F23 |
| "Every type in the sketches is defined" | seven were not | I-05, SC-19 |
| "set-once: a second .input()/.output() is a type error" | not while the slot is Unit | F8 (I-07) |
| "client/retry moved verbatim; FakeClock `start_unix_ms?`" | ported; today's form is `start_unix_ms~ : Int64 = 0L` | I-12, CM-15 |
| "Named schemas are hoisted into components" (nested, recursive) | nested ones were inlined; recursion did not compile | SC-01 |
| "A pattern validator uses the same pattern it documents" | lexmatch vs ECMA-262 | F22 (SC-02) |
| "One Middleware type replaces tapir's interceptors" | needed route info after `next` and a shaped 500 | SC-06 |
| "Auth atoms become securitySchemes" (sufficient) | two required credentials were documented as OR | SC-05 |
| "`PartialRequest::base_url` replaces sdk-runtime base_url" | RFC 3986 drops /v1, /api/v3, /api/v10 | F23 (CM-01) |
| "SDK phase 1 is an import-table change; keep `@http` to shrink diffs" | builder calls and the URL type change the emitter | CM-02 |
| "Generated decoders via `as_bytes_always().map_with_head`" | 403/429 are no longer retried | CM-04 |
| "SdkError::Config is construction-time only" | raised at call time by encoders | CM-12 |
| "One mechanism per concern" | eleven duplications | S-04 |
| "A single `testing` package ships in Stage 0" | its endpoint helpers did not exist yet, and it would compile the endpoint layer into every SDK test | S-06 |
| "run_sync fits deny-warn" | unused_async; fixed per package | F19 (S-14) |
| "Two event loops are assumed not to work (unverified)" | confirmed | F35 |

Corrections to the previous draft (from the final critique, each checked against the sources):

| Claim of the previous draft | Finding | Evidence |
|---|---|---|
| "The loop resends a non-idempotent request only if unsent or idempotent" | contradicts `stainless`, which openai and anthropic use; method gating belongs to the decider | F58 |
| "Every Client-loop rule has a test in wf3/rev" | four client tests; the deadline rules, `body_fn`, replayability and limiter-wait rules are untested, and `client/retry` is a stand-in | F44, F59 |
| "An unreplayable body is never resent" (in wf3/rev) | the loop only hands `replayable` to the decider; a custom decider can resend a consumed stream | `wf3/rev/mttp/src/client/client.mbt` |
| "`client/ratelimit` moves verbatim" | it names `@http.Headers` and `@sync.Gate` | sdk-runtime mbti |
| "`ClientRequest::new(.., options?)` is enough" | no client-wide default can be merged; every v0.1 consumer needs one | `discord/src/http/client.mbt`; SDK constructors |
| "The endpoint uses the operation id as the bucket" | GitHub and discord bucket by method, URL and route | `github/src/call.mbt` |
| "`fetch_handler(req, env, ctx)` replaces discord's JS facade" | Workers-only; five other hosts | F61 |
| "`RequestMethod` is gaato/http's" | moonbitlang/async/http's | F60 |
| "Generated `*_request` raise `SdkError::Config`" | they never do; multipart ones raise MultipartError | F62 |
| "wf3/rev passes `--deny-warn`" | 84 warnings | F53 |
| "`Input::new` is usable by third parties" | not outside the package | F55 |
| "Stage 0 creates the mttp repo" | it exists, empty | F64 |
| "The consumers are discord, the SDKs, codex-protocol and requesto" | kbbi and discord-cli are published consumers too | F56 |


## 11. Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | The Driver depends on undocumented `%async` intrinsics. | One file; a daily canary diffs it against core's `async_primitive.mbt`; driver is experimental, so a change does not break the stable surface. |
| 2 | core/async is experimental and still renames APIs. | Only mttp_async imports it; its adapters are private (`internal/`), and the mbti gate keeps its types out of every public signature. |
| 3 | The flag day: gaato/http 0.6 breaks every graph that also holds a 0.5-only library (F28). | Publish it only in the train with the SDK re-releases (§5.8); the resolver gate builds the SDKs and discord from outside before the train. |
| 4 | Under MVS, breaking 0.x releases propagate and patches do not. | Coordinated minimum bumps; `/v2` paths reserved. |
| 5 | Workspace builds hide consumer resolutions. | Resolver gate outside moon.work. |
| 6 | Experimental opt-in semantics are new: whether the list form works from `.mbtx` scripts and from inside the same module is unverified. | The workspace PR probes both; scripts may stay on moonbitlang/async 0.22.5 as a documented exception. |
| 7 | Moving the engines' tests from sockets to sim may lose coverage of real socket behaviour. | Keep the socket suites in http-async (native, wasm); the coverage ledger records any line covered only there. |
| 8 | Closure-erased endpoints: hand-built `Input::new` atoms can disagree with their closures. | `verify`, round-trip properties. |
| 9 | Readers inside retried attempts must be pure; a side-effecting buffered reader runs again. | Documented; streaming callbacks run once. |
| 10 | JS limits: fetch follows redirects, merges headers, hides Set-Cookie and decodes codings; request bodies are buffered; each serverless host keeps deferred work alive differently. | Per-target CONTRACT exceptions; host-neutral `fetch_handler` with per-host shims. |
| 11 | wasm (moonrun) async is experimental; wasm-gc has no runtime. | Per-target test counts; portable tests through `run_sync`; the README tells wasm-gc users to supply `rt`. |
| 12 | The credentials-first ordering may surprise tapir users. | Documented; overridable via `decode_failure` (P-04). |
| 13 | Unmeasured costs: immutable Headers copies, closures per request, persistent control states. | `benchmarks/` (state copies, one reused TCP connection) before release. |
| 14 | String URLs surface invalid targets only at send time (`Kind::Invalid`, unsent). | Accepted (X-01); `uri()` for builders. |
| 15 | The ECMA pattern translator covers only a subset. | Corpus from the three SDK specs; refusal at construction. |
| 16 | The endpoint layer left experimental on 2026-11-11 and now follows the §5.6 evolution rules; a break needs a minor release of gaato/mttp. | `#non_exhaustive` enums, frozen field sets, apispec typing 3.2's fields already (§0.0). |
| 17 | Migration size: discord's public API, three generated SDKs (github ≈ 243k lines), discord_voice, requesto users. | Mechanical emitter changes; isolated migration worktrees; one break for discord instead of two. |
| 18 | Users reach for `moonbitlang/core/async/http` for production work. | §0.1 and the READMEs state its gaps (F65); upstream reports are a separate, owner-approved task. |
| 19 | Frozen old-stack graphs strand users of requesto 0.2, kbbi 0.1 and discord ≤ 0.13. | Every gaato consumer moves in the train; requesto's last release documents the migration. |

## 12. Open questions

Answered: Q1–Q4, Q6–Q8, Q11 and Q12 in §0.2; Q3 again, Q5, Q6, Q14, Q15 and Q16 by §0.1 (no facade; mttp and http-async share only gaato/http; `gaato/http-async`; discord breaks once; old-stack graphs frozen; kbbi and discord-cli migrate). Q9 is moot: discord's interactions listener moves to `@server.serve` over `h1server` in the train. Q13 is answered by §5.8: sdk-runtime and requesto are deprecated, gaato/http and http-async are not.

Closed on 2026-11-11 (§0.0): SDK phase 2 (declined), AsyncAPI (declined), an endpoint core without the client (declined), the OpenAPI version (3.1 now, 3.2's fields typed).

Waiting on outside facts, each saying what it waits for:

1. **OpenAPI 3.2 output**: until openapi-generator (swagger-parser) and Redoc read 3.2. The move renames `x-oai-itemSchema` to `itemSchema` and sets the version.
2. **WebSockets** (and with them AsyncAPI): until core/async's websocket bounds its frames and checks masking (X-06; core's review tracks both).
3. **HTTP/2**: until core/tls offers ALPN (F67).
4. **Upstream**: a new core issue proposing a runtime-independent HTTP vocabulary (referencing #4613 and #4686), and a report that core/async/http mishandles status lines without a reason phrase, which core's review does not cover. Both go out after the owner reads the drafts; the head bound and CL+TE are already core's P0-2.

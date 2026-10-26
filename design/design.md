# mttp design (draft)

> The exception-first Client/Endpoint sketches and migration tables in this
> original design are historical. The accepted follow-up contract is
> [Typed responses and SDK contracts](result-api-refactor.md); it replaces
> their response modes, expected failures, retries and whole-call deadlines.
> Current public signatures are generated in each package's `.mbti` file.

**Status: accepted as the basis for implementation (2026-10-24).** The decisions the user made are listed in §0 and override anything below that says otherwise. Items still marked **[needs-prototype]** are settled by the pre-flight probes or during implementation; remaining **[proposed]** items are the defaults.

This draft revises the first synthesized architecture using six adversarial reviews: cross-layer integration, resolver and release, async runtime and I/O, sttp/tapir completeness, consumer migration, and scope. The design was then rebuilt as a single prototype that compiles and passes on every target. A final critique was checked against the gaato sources, the registry index and the prototypes, and its corrections are folded in. Where a rule is designed but not yet tested in `wf3/rev`, the text says so.

> **Note on paths.** The prototypes cited below were built in a temporary session directory. The main one, `wf3/rev`
> (31/31 tests on wasm-gc, js, native and wasm), later grew review fixes, the moved `sse` parser and their tests (65/65)
> as `design/prototype/` on branch `ccr-eae554e2-r0xapl-prototype` (commit 105d062); it is no longer in the tree.
> The other cited prototypes (`wf2/*`, `synth/probe`) are kept as sources on branch `ccr-eae554e2-r0xapl-seeds`.

| Prototype | Path (under `/tmp/claude-0/-home-user/a088a40a-4430-5968-a906-ca92585d97e4/scratchpad/`) | Result |
|---|---|---|
| **Revised design, end to end** (model, clock, client, schema, endpoint, endpoint/testkit, router, apispec, openapi, testing, plus an app with a definition package and e2e tests) | `wf3/rev` | 31/31 tests pass on wasm-gc, js, native and wasm with moonc 0.10.16+b1a0e846e (pinned) and with 0.10.17+d971670cd |
| Integration prototype of the first architecture | `wf2/integration` | 27/27 tests pass on 4 targets (re-run on 0.10.17) |
| v0.1-sized client (one request type plus a Client bundle) | `wf2/scope/v01` | 4/4 pass (re-run on 0.10.16, wasm-gc and native) |
| Resolver experiments (isolated MOON_HOME, fake registry) | `wf2/resolver` | see §10 |
| Runtime adapters (moonbitlang/async 0.22.5 and core-main async) | `wf2/runtime` | see §10 |
| Completeness probes (schema, outputs, regex, security) | `wf2/completeness` | 4 targets × 2 toolchains |
| Consumer ports (discord REST, GitHub, OpenAI SSE, URL join, bridge) | `wf2/consumer-migration` | 4 targets × 2 toolchains |
| Final-review probes (suberror evolution; warning census; arrow-lambda handlers) | `v4/ne`, `v4/rev` (a copy of `wf3/rev`) | see F52–F54 |

Toolchains used: `moon` on PATH is moon 0.1.20261023 with moonc v0.10.17+d971670cd; the pinned toolchain is moon 0.1.20261016 with moonc v0.10.16+b1a0e846e (`wf2/bin/m16`). Neither ships core async. The final-review probes ran on the moon on PATH (0.10.17).

---

## 0. Decisions

Made by the user on 2026-10-24; they supersede the corresponding [needs-user-input] items.

| Topic | Decision | Replaces |
|---|---|---|
| Scope | v0.1–v0.4 are implemented; the endpoint layer, router, openapi and the test toolkit ship as **experimental** in 0.1.x, outside the §5.6 freeze. WebSockets are deferred (see X-06). | V-01, Q1, Q12 |
| PRs | This document lands on its own; the implementation follows as stacked PRs, one per review unit (≲ 5k lines, fully gated). Merge commits. Nothing is published from them; publishing stays behind M-11. | — |
| `Request.url` | `String`. The raw string is refused if it contains space, CR, LF or other controls (before parsing: the WHATWG parser strips them), then parsed strictly at send time; the backend re-serialises the request target from the parsed form and validates headers. No URL type exists in core, core/async, moonbitlang/async or moonbitlang/x; async#368 only says one may be bundled later. | X-01, Q2 |
| Module names | `gaato/mttp`, `gaato/mttp-net`, and `gaato/mttp-digest` (DigestScheme; the only importer of moonbitlang/x). Later third-party integrations follow sttp/tapir: `gaato/mttp-<lib>-backend`, `gaato/mttp-<lib>-server`. The tapir-equivalent packages stay inside `gaato/mttp` for now. | M-04, M-07, Q6 |
| Facade | sttp style: `mttp-net/quick` (a lazy default backend and `send(req)`) and `client.quick_request(req)` (a string body for any status). requesto is deprecated later; its keyword-argument API is not carried over. | M-06, Q3 |
| jsonkit | `gaato/mttp/jsonkit` (default kept). | M-03 |
| Shim | None (G-02 default (d)). | G-02, Q4 |
| Server | 400 for invalid bodies; credentials first (defaults kept). | P-04, P-05, Q7, Q8 |
| WebSockets | Not now: core/async's websocket lacks size bounds, aborts on misuse, needs a concurrent reader for ping, never waits for the peer's Close, validates UTF-8 loosely, sends a fixed 101 header set, has no js/wasm-gc support, and upgrades only an `@http.ServerConnection`. Reserved hooks: `Response.attributes`, an internal 101 hand-off in the h1 server loop, no compression on 101, no runtime type in any public signature. | X-06, Q12 |
| Test architecture | A runtime-free deterministic `testing/driver` (virtual time, spawn/park/cancel) and contract-bound doubles; no `async test` in gaato/mttp; the existing VirtualClock is redesigned rather than preserved. Details land with the implementation. | §4.10, §5.7 |

## 1. Goals and non-goals

| Goals | Non-goals |
|---|---|
| One HTTP library family for gaato's MoonBit code, with sttp's split of responsibilities: vocabulary (sttp-model), client (client4), endpoint descriptions with server and client interpreters (tapir), and a spec model (sttp-apispec) | sttp's type machinery: F[_], capability type parameters, a sttp-shared layer |
| Sans-IO by default: every package except the I/O module builds and tests on wasm-gc, wasm, js and native | A second runtime, or code that runs on two event loops in one process |
| Move gaato's existing consumers (discord, discord_voice, discord-cli, openai, anthropic, github, codex-protocol, requesto; kbbi per §12 Q16) onto one stack, with one retry loop, one error pair and one transport trait | Keeping gaato/http, http-async and sdk-runtime as parallel long-term APIs |
| Keep gaato's strengths: injected clock and randomness; bounded-by-default with ledgers; phase-tagged errors with `is_unsent`; the incremental SSE parser; deterministic tests on every target | HTTP/2, server TLS, AsyncAPI and WebSockets in the first three releases |
| A first release (v0.1) that is just big enough to move the client consumers, with later tiers that are additive | Shipping every sttp and tapir concept at once (§7 stages them) |

## 2. Principles

1. **sttp's split of responsibilities, not its types.** The layers are vocabulary, client, endpoint description, interpreters and spec model.
2. **Sans-IO by default.** Only `gaato/mttp-net` touches sockets, the event loop or JS host objects. Async tests of sans-IO code run through a runtime-free driver (`run_sync`).
3. **Injected nondeterminism.** Clock, Timer, Gate and randomness are always passed in. No code reads wall time or calls a global RNG.
4. **Bounded by default; refuse rather than degrade.** Every bound has a RESOURCE_BOUNDS row and a test.
5. **Transport failures carry their phase.** `is_unsent` decides whether a non-idempotent request may be resent.
6. **One mechanism per concern.** There is one sending path (`Client::send`), one wrapper form (a `Backend`, or `from_fn`), one attempt deadline, one bucket channel, one body direction (pull), one response type for both directions and one definition checker. §5.10 lists the mechanisms that were removed.
7. **Codegen is optional.** Generated code is code a person could write by hand.
8. **Module boundaries exist only for external dependencies**, because a module's imports reach every consumer's download set and version selection (verified, §10 F31). Target isolation is *not* a module reason: per-package `supported_targets` does it inside one module. A module split isolates consumers' versions only if the parts are versioned independently and non-breaking changes ship as patches (verified, F32).
9. **No public signature names a runtime type** (TaskGroup, `@io.Reader`, a js_async Promise). This keeps signatures stable across the runtime switch. It does *not* keep consumers' manifests stable (§8, Stage R).
10. **Evolution rules from v0.1.** Every `pub(all)` enum that may grow is `#non_exhaustive`. `pub(all)` struct field sets are frozen at release, and users build these structs through `::new`/`::default()` plus record update. Suberrors cannot be made non-exhaustive, so a suberror that may grow carries a `#non_exhaustive` kind enum; every other suberror is frozen at release (§5.6).

## 3. Module and package map

### 3.1 Modules

| Module | Kind | Depends on | Why it is a module |
|---|---|---|---|
| `gaato/mttp` | sans-IO core, all 4 targets | moonbitlang/core only | Any consumer, on any target, can import it without pulling a runtime, codecs or crypto into its graph. |
| `gaato/mttp-net` **[needs-user-input: name]** | the only I/O module | gaato/mttp, moonbitlang/async 0.22.5 (later moonbitlang/core/async), gaato/codec_bytes, gaato/deflate, gaato/brotli, gaato/zstd | External dependencies. Each consumer of a module downloads, and is version-lifted by, all of that module's imports (F31), so these must stay out of gaato/mttp. |
| `gaato/mttp-gen` | tool, **later** | moonbitlang/parser (which drags moonbitlang/async, moonbitlang/x and more) | A tool, installed with `moon install` and never listed in any moon.mod (F51). Dropped until a consumer needs it. |
| `gaato/http` 0.5.x, `gaato/http-async`, `gaato/sdk-runtime`, `gaato/requesto` | existing published paths | — | Kept unchanged during migration, then deprecated (§8). A `gaato/http` 0.5.1 is cut only if the optional bridge is wanted (G-02). |

Unpublished members of the repository: `mttp/conformance` (corpora, ledger checks, cross-layer e2e suite) and `mttp/net-tests` (loopback, adversarial server probes, runtime-paired builds).

`gaato/clock` and `gaato/jsonkit` are **not** separate modules any more. Every importer of the gaato/http clock is HTTP-stack code or depends on discord. The only non-HTTP user of sdk-runtime/json (codex-protocol) already imports sdk-runtime. A consumer compiles only the packages it imports (F18), so a non-HTTP importer of `gaato/mttp/clock` compiles one package.

### 3.2 Packages of gaato/mttp

All of them build on all four targets. "Tier" is the release that first ships the package (§7).

| Package | Tier | Responsibility | sttp/tapir counterpart |
|---|---|---|---|
| `clock`, `clock/fake` | v0.1 | Clock, Timer, Gate traits, `default_random`; FakeClock | — |
| `jsonkit` | v0.1 | sdk-runtime/json moved: Presence, ObjBuilder, field helpers, open enums | — |
| `model` | v0.1 | Wire vocabulary: Method, Headers, Url, Request/Response (+ heads), Body/BodyStream, TransportError, Attributes, helpers | sttp-model + AttributeMap |
| `sse` | v0.1 | SseEvent, the incremental SseParser (moved); writer at v0.3 | sttp-model sse |
| `multipart` | v0.1 | Writer (moved, with MultipartError; an explicit boundary, or one drawn from injected randomness); bounded reader later | sttp-model Part |
| `client` | v0.1 | Backend, RequestOptions, ResponseAs, ClientRequest, Client (the policy loop), RetryDecider, RateLimiter, Paginator; FollowRedirects at v0.2. Imports model, clock, sse, client/retry | client4 core, wrappers, RetryWhen |
| `client/retry` | v0.1 | Retry decisions as data, ported from gaato/http/retry. Imports model only | RetryWhen (more) |
| `client/ratelimit` | v0.1 | WindowLimiter, Pace, GlobalWindow, LimitScope, rate_limit_headers (ported from sdk-runtime). Imports client (to implement `RateLimiter`) and clock | — |
| `client/cookies` | v0.2 | The `Cookies` Backend wrapper. Imports client and cookie, so v0.1 client users never compile the jar | client4 cookie handling |
| `testing` | v0.1 | run_sync, BackendStub, check_splits, Backend/BodyStream contract checkers. Imports model and client only | client4 testing |
| `cookie` | v0.2 | RFC 6265 CookieJar (moved, clock injected); server helpers at v0.3 | CookieWithMeta + storage |
| `h1` | v0.3, or v0.2 if §12 Q9 (c) is chosen | **New.** Sans-IO HTTP/1.1 codec: bounded head scanner and parser, chunked decoder, framing rules, response serializer. Depends only on model, so it can ship ahead of the endpoint layer | (netty codec) |
| `schema` | v0.3 | Schema (JSON Schema 2020-12 plus defs), Issue, DecodeFailure, Validator, TextCodec, JsonCodec, BodyCodec. Imports core and jsonkit, not model | tapir Codec, Schema, Validator |
| `endpoint` | v0.3 | Atoms and staged Inputs, Out/Variant, Errors, Endpoint builders, server dispatch, client interpreter, the definition checker | tapir core + interpreters |
| `endpoint/testkit` | v0.3 | when_endpoint, verify | tapir testing / stub |
| `router` | v0.3 | Router, ServerOptions, Middleware, problem+json, `impl Backend for Router` | tapir server core + stub server |
| `apispec`, `openapi` | v0.4 | Typed OpenAPI 3.1 model; to_openapi, docs_endpoint, check_documented | sttp-apispec, tapir openapi-docs |

### 3.3 Packages of gaato/mttp-net

| Package | Tier | Targets | Responsibility |
|---|---|---|---|
| `backend` | v0.1 | native, wasm, js | AsyncBackend: http-async's AsyncTransport ported to the single-send Backend (pool, phase timeouts, proxy and NO_PROXY, bounded decoding, 64 KiB write slices) |
| `codings` | v0.1 | all 4 | Bounded ContentDecoder and coding_plan; ContentEncoder and negotiation at v0.3 |
| `runtime` | v0.1 | native, wasm, js | AsyncClock, ClockTimer, SemaphoreGate, with_timeout_opt, VirtualClock |
| facade (`quick` or requesto 0.3) | v0.2 | native, wasm, js | Exactly one script-level facade **[needs-user-input, M-06]** |
| `server` | v0.3 | native, wasm | `serve(handler, addr~, ...)` over Tcp, using the `h1` codec |
| `fetch` | v0.3 | js | Host-neutral `fetch_handler`, plus small JS entry shims for Workers, Fastly, Vercel, Deno, Bun and AWS Lambda URLs (the hosts discord supports today) |
| `files` | later | native, wasm | Static files over an abstract file source |
| `internal/io` | Stage R | — | Runtime bridges. The `internal/` path keeps them out of consumers' reach (the convention discord already uses in `discord/src/internal`) |

### 3.4 Dependency diagram

```
moonbitlang/core
   │
   ▼
gaato/mttp  (sans-IO; core only; wasm-gc, wasm, js, native)
   (A ──► B means "A imports B")

   clock/fake ──► clock
   model                        (core only)
   sse, multipart, h1 ──► model
   cookie ──► model, clock
   client/retry ──► model
   client ──► model, clock, sse, client/retry
   client/ratelimit ──► client, clock
   client/cookies ──► client, cookie                     (v0.2)
   testing ──► model, client
   schema ──► jsonkit                                    (no model edge)
   endpoint ──► model, schema, client
   router ──► model, schema, client, endpoint
   endpoint/testkit ──► model, client, endpoint, router, testing
   apispec                      (core json only)
   openapi ──► model, schema, endpoint, apispec

gaato/mttp-net (I/O) ──► gaato/mttp
   backend, codings, runtime | server(──► h1), fetch | facade | internal/io
   + moonbitlang/async 0.22.5 → moonbitlang/core/async (Stage R)
   + gaato/codec_bytes, gaato/deflate, gaato/brotli, gaato/zstd

consumers ──► mttp (+ mttp-net): gaato/discord, gaato/discord_voice, gaato/discord-cli,
           gaato/{openai,anthropic,github}, codex-protocol, (gaato/requesto 0.3?), gaato/kbbi?, apps
tools (never imported): mbt-sdk tools/gen (Python); gaato/mttp-gen (later)
```

The `client`, `client/retry`, `testing`, `endpoint`, `router`, `endpoint/testkit` and `openapi` edges are the imports of `wf3/rev`. The `sse`, `jsonkit`, `client/ratelimit` and `client/cookies` edges follow from the sketches in §4: `as_sse` takes `@sse.SseEvent`, `schema.presence` returns `@jsonkit.Presence`, and WindowLimiter implements `@client.RateLimiter`.

Rule: an endpoint-definition package imports only `model`, `schema` and `endpoint`, never `mttp-net`. In `wf3/rev/app/src/api` such a package checks on wasm-gc. Every package that imports a target-restricted package declares `supported_targets` itself; otherwise whole-module checks for other targets fail (F17).

### 3.5 Responsibility rules

- **model** names things on the wire. No policy, no I/O, no codec beyond HTTP syntax.
- **client** sends requests. A policy goes in one of three places:
  - a **Backend wrapper**, if it needs only the request and the response head: redirects, cookies, header injection, wire logging;
  - the **Client loop**, if it must see the decoded outcome or pair work across one attempt: retry, rate-limit admission and release, deadlines, the attempt observer;
  - the **Client defaults**: base URL, default headers.
- **h1** turns bytes into request heads and framing, and response heads into bytes. No sockets.
- **schema** converts and describes values. It knows nothing about HTTP.
- **endpoint** describes operations and interprets *one* endpoint, on the server and on the client.
- **router** chooses the endpoint and applies server-wide policy. It is both a Handler and a client Backend.
- **apispec** is document data; **openapi** projects endpoints onto it.
- **testing** and **endpoint/testkit** hold doubles, drivers and checkers. No production package imports them.
- **mttp-net** owns everything that touches sockets, the event loop, JS host objects and compression.

## 4. Layer-by-layer design

The sketches use 0.10.16/0.10.17 syntax. Bodies are omitted. For gaato/mttp, a signature not marked `(new)` or `(moved)` compiled in `wf3/rev`; `(new)` means designed but not compiled there; `(moved)` means today's hardened code is kept. For mttp-net (§4.11), unmarked signatures are http-async's existing API (moved) or compiled in `wf2/runtime` (AsyncBackend::new/send, serve, ServerLimits, ServerConfigError with Bind, fetch_handler(handler)); everything else there is marked `(new)`. The `#non_exhaustive` attributes and read-only visibilities required by the evolution rules (§5.6) are applied throughout the sketches, though `wf3/rev` has only some of them.

### 4.1 clock and jsonkit

```moonbit
// gaato/mttp/clock (moved from gaato/http/clock, sync, random)
pub(open) trait Clock { async fn sleep(Self, Int) -> Unit noraise; fn now_unix_ms(Self) -> Int64 }
pub(open) trait Timer { async fn within(Self, Int, async () -> Unit noraise) -> Bool noraise }
pub(open) trait Gate  { async fn acquire(Self) -> Unit noraise; fn release(Self) -> Unit }
pub fn default_random() -> Double

// gaato/mttp/clock/fake (moved from gaato/http/mock; today's labelled-with-default form)
pub fn FakeClock::new(start_unix_ms~ : Int64 = 0L) -> FakeClock
pub fn FakeClock::advance(self : FakeClock, ms : Int) -> Unit
pub fn FakeClock::slept(self : FakeClock) -> Array[Int]
pub impl @clock.Clock for FakeClock
pub extend FakeClock with @clock.Clock::{sleep, now_unix_ms}   // (new) today's FakeClock has them as regular methods
```

`pub extend` keeps `clock.now_unix_ms()` callable on the concrete type without the deprecated implicit promotion that the gaato manifests silence with `-implicit_impl_as_method`. `wf3/rev`'s FakeClock has only the trait impl. AsyncClock, ClockTimer and SemaphoreGate (§4.11) get the same declaration.

The traits are new traits with today's names and signatures. They are not `pub using` re-exports of gaato/http's (see G-02). Real clocks need a runtime and live in `mttp-net/runtime`.

`gaato/mttp/jsonkit` (moved): `Presence[T]` (Absent/Null/Value), `ObjBuilder`, `field`, `opt_field`, `presence_field`, `expect_object`, `open_int`, `open_string`. The package is named `jsonkit`, not `json`, because the alias `@json` would collide with core's.

### 4.2 model

```moonbit
#non_exhaustive
pub(all) enum Method { Get; Head; Post; Put; Delete; Connect; Options; Trace; Patch; Other(String) } derive(Eq, Hash, Debug)
pub fn Method::parse(s : String) -> Method
pub fn Method::to_string(self : Method) -> String
pub impl Show for Method                     // "\{m}" needs it (E4018 otherwise)
pub fn Method::is_idempotent(self : Method) -> Bool

pub struct Headers { priv pairs : Array[(String, String)] }   // immutable, ordered, duplicates kept, case-insensitive lookup
pub fn Headers::empty() -> Headers
pub fn Headers::of(pairs : ArrayView[(String, String)]) -> Headers
pub fn Headers::get(self : Headers, name : String) -> String?      // get_all, add, set, remove, iter, length
pub fn Headers::validate(self : Headers) -> Unit raise TransportError // CR/LF/NUL, token names

#non_exhaustive
pub(all) enum Phase { Pool; Dial; Write; Head; Body; Unknown } derive(Eq, Debug)
#non_exhaustive
pub(all) enum Kind { Invalid; Connect; Timeout(ms~ : Int); Network; Protocol; Proxy(status~ : Int)
  TooLarge(limit~ : Int); TooManyRedirects(max~ : Int); RedirectRefused; Unreplayable; Closed } derive(Eq, Debug)
pub(all) suberror TransportError { TransportError(kind~ : Kind, phase~ : Phase, detail~ : String) } derive(Debug)
pub fn TransportError::is_unsent(self : TransportError) -> Bool
pub fn TransportError::message(self : TransportError) -> String

pub(open) trait BodyStream {                 // CONTRACT 9-11: None = end and stays end; chunks never empty; close idempotent
  async fn read_some(Self) -> Bytes? raise TransportError
  fn close(Self) -> Unit
}
#non_exhaustive
pub(all) enum Body { Empty; Bytes(Bytes); Stream(&BodyStream, length~ : Int64?) }
pub fn Body::is_replayable(self : Body) -> Bool
pub impl Eq for Body                         // (new) Bytes by value, Stream by physical identity (as StreamBody today)
pub impl @debug.Debug for Body               // (new) Stream printed as its length and taken state
pub async fn read_bounded(s : &BodyStream, limit : Int) -> Bytes raise TransportError   // refuses at the crossing chunk
pub fn BytesStream::new(chunks : Array[Bytes]) -> BytesStream                          // test double; impl BodyStream

// typed attributes: sttp-shared AttributeMap without Any (per-key slot plus closures)
pub fn[T] AttributeKey::new(name : String) -> AttributeKey[T]
pub fn Attributes::empty() -> Attributes
pub fn[T] Attributes::put(self : Attributes, key : AttributeKey[T], value : T) -> Attributes
pub fn[T] Attributes::get(self : Attributes, key : AttributeKey[T]) -> T?
pub let remote_addr : AttributeKey[String]                    // set by server adapters
pub let replay_safe : AttributeKey[Bool]                      // "resend is safe even after the write" (replaces discord's header)
pub let background : AttributeKey[(async () -> Unit) -> Unit] // (new, v0.3) set by adapters: fetch adds to the promise given to JsBackground; server starts a task

pub(all) struct Request { meth : Method; url : String; headers : Headers; body : Body; attributes : Attributes }
pub fn Request::new(meth : Method, url : String) -> Request
pub fn Request::get(url : String) -> Request                  // post, put, delete; patch, options (new, v0.1: SDK phase 1 needs patch)
pub fn Request::header(self : Request, name : String, value : String) -> Request  // set_header, bearer, query; basic (new)
pub fn Request::body_bytes(self : Request, b : Bytes, content_type? : String) -> Request
pub fn Request::body_json(self : Request, j : Json) -> Request // body_text, body_stream(length?, content_type?); body_form (new)
pub fn[T] Request::attribute(self : Request, key : AttributeKey[T], value : T) -> Request
pub fn Request::head(self : Request) -> RequestHead
pub(all) struct RequestHead { meth : Method; url : String; headers : Headers } derive(Eq, Debug)
pub fn is_idempotent(req : Request) -> Bool                   // method, Idempotency-Key header, or replay_safe

pub(all) struct ResponseHead { status : Int; headers : Headers } derive(Eq, Debug)
pub(all) struct Response { status : Int; headers : Headers; body : Body; attributes : Attributes }  // both directions
pub fn Response::new(status : Int, headers? : Headers, body? : Body) -> Response
pub fn Response::head(self : Response) -> ResponseHead
pub fn Response::close(self : Response) -> Unit
pub fn Response::closes_connection(self : Response) -> Bool   // "Connection: close"

// URLs: gaato/http's WPT-tested parser (moved), plus string helpers for targets
pub fn Url::parse(s : String) -> Url raise UrlError
pub fn Url::resolve(self : Url, reference : Url) -> Url       // RFC 3986: for redirects, never for base URLs
pub fn Url::path_segments(self : Url) -> Array[String] raise UrlError   // decoded, for routing
pub fn Url::query_params(self : Url) -> Array[(String, String)]
pub fn join_url(base : String, target : String) -> String     // prefix join: ".../v1" + "/chat" = ".../v1/chat"
pub fn encode_path(segments : Array[String]) -> String
pub fn append_query(url : String, name : String, value : String) -> String
// moved helpers: retry_after_ms, parse_retry_after, parse_link_next, format_http_date, parse_http_date,
// percent_encode, percent_encode_path, percent_decode, form_urlencode, form_urldecode(max_pairs? = 256),
// is_success, reason_phrase
// v0.2: UriBuilder / UriPart / Trusted, uri(f) -> String   (no parse, so no raise)
// v0.3: pub type Handler = async (Request) -> Response noraise; MediaType, negotiate
```

Design notes:

- **`Request.url : String`** **[needs-user-input, X-01]**. It holds an absolute URL or a relative reference, exactly as gaato/http does today. Backends parse it once at send time; a bad URL becomes `TransportError(kind=Invalid, phase=Pool)`, which counts as unsent. This keeps generated SDK code non-raising (CM-02, S-11). With a read-only `Url` field, generated code would either fail with E4036 or need `Url::parse` and a new `raise` on about 1000 functions. A typed alternative is in §12.
- **One `Response` for both directions.** A server closes the connection after a response with `Connection: close`. `ServerResponse`, `ServerBody` (including `Push`) and `Outcome` are gone. `Response.attributes` is the response-side channel: FollowRedirects records the final URL and history there (v0.2), and the router records the matched route template (verified).
- **Request construction.** `Request::head()` returns the head, so a HEAD request is built with `Request::new(Head, url)`.
- **Stream bodies are taken once.** `Body::Stream` keeps today's take-once guard (CONTRACT 8, `StreamBody::take` and `TakenStream`). The stream sits in a take-once cell; a second take raises `TransportError(kind=Unreplayable, phase=Pool)`, which counts as unsent. `wf3/rev`'s `Body::Stream` has no such cell yet **[needs-prototype]**.
- **Eq and Debug on Body.** The moved multipart `Part` derives `Eq` and `Debug` over its body, and tests assert on Requests and Responses, so `Body` implements both as `StreamBody` does today. `wf3/rev`'s `Body` has neither.

### 4.3 sse, multipart, cookie

| Package | v0.1 | Later |
|---|---|---|
| `sse` | Moved: `SseEvent{event, data, id, retry}`, `SseParser::new(max_event_bytes? = 16 MiB)`, `feed`, `finish`. On overflow, `feed` and `finish` raise `@model.TransportError(kind=TooLarge(limit), phase=Body)` (today: `HttpError::Protocol`) | v0.3: `encode(SseEvent) -> Bytes` |
| `multipart` | Moved writer, with its errors. `body(req : @model.Request, parts : Array[Part], boundary~ : String) -> @model.Request raise MultipartError` (new name for `apply`; generated code passes its `boundary` parameter); `encode_segments_fresh(parts, random~)` kept (discord's `encode_parts` uses it); `make_boundary(random)`. `MultipartError` keeps InvalidBoundary, BoundaryCollision, InvalidHeaderValue and StreamPart | Later: `MultipartReader::new(boundary, max_parts? = 128, max_header_bytes? = 8192, max_part_bytes?)` |
| `cookie` | — | v0.2: `CookieJar::new(clock, max_per_domain? = 50, max_total? = 3000, is_public_suffix?)` (moved); v0.3: `SetCookie::to_header`, `parse_cookie_header` |

### 4.4 client

```moonbit
pub(all) struct RequestOptions {          // frozen field set; build with default() + record update
  timeout_ms : Int?          // attempt deadline: until the head, and with body_deadline until the end of the body
  body_deadline : Bool       // set by Client::send: true for buffered readers, false for streaming ones (RT-07)
  read_idle_ms : Int?        // per read on a streamed body (SSE idle; replaces requesto's per-call idle timeout)
  max_body_bytes : Int       // buffered readers, counted after decoding; 64 MiB
  follow_redirects : Bool    // honoured by FollowRedirects (v0.2)
  max_redirects : Int        // 10
  decompress : Bool          // true (default); see "Content codings" below
} derive(Eq, Debug)
pub fn RequestOptions::default() -> RequestOptions

pub(open) trait Backend {
  async fn send(Self, @model.Request, RequestOptions) -> @model.Response raise @model.TransportError
  fn close(Self) -> Unit = _
}
pub type SendFn = async (@model.Request, RequestOptions) -> @model.Response raise @model.TransportError
pub fn from_fn(f : SendFn, on_close? : () -> Unit) -> &Backend       // the one ad-hoc wrapper form; arrow lambdas fit

pub(all) suberror ResponseError {
  UnexpectedStatus(@model.ResponseHead, body~ : Bytes)                 // body kept up to max_error_body = 1 MiB
  Deserialization(@model.ResponseHead, message~ : String, body~ : Bytes)
} derive(Debug)
pub(all) suberror InvalidRequest { InvalidRequest(message~ : String) } derive(Debug)  // raised by encoders, never sent
pub fn status_of(e : Error) -> Int?

// how to read a response
pub fn[T] ResponseAs::new(
  read : async (@model.ResponseHead, @model.Body, RequestOptions) -> T,
  accept_head? : (@model.ResponseHead) -> Bool,         // default: 2xx
  reject? : (@model.ResponseHead, Bytes) -> Unit raise, // runs inside the attempt on the buffered error body; default raises UnexpectedStatus
  streaming? : Bool,                                    // applies to the accepted body only
) -> ResponseAs[T]
pub fn as_bytes() -> ResponseAs[Bytes]                  // as_string, as_json_value, ignore_body
pub fn[T : FromJson] as_json() -> ResponseAs[T]         // Deserialization on failure
pub fn[T] as_stream(f : async (@model.ResponseHead, &@model.BodyStream) -> T) -> ResponseAs[T]  // streaming; closed after f
pub fn as_sse(f : async (@sse.SseEvent) -> Unit, max_event_bytes? : Int, stop? : (@sse.SseEvent) -> Bool) -> ResponseAs[Unit] // (new) stop: "[DONE]"
pub fn[T] from_head(choose : (@model.ResponseHead) -> ResponseAs[T]) -> ResponseAs[T]   // the chosen reader runs inside the attempt
pub fn[T] ResponseAs::any_status(self : ResponseAs[T]) -> ResponseAs[T]                // replaces the _always twins
pub fn[A, B] ResponseAs::map(self : ResponseAs[A], f : (A) -> B raise) -> ResponseAs[B]
pub fn[A, B] ResponseAs::map_with_head(self : ResponseAs[A], f : (A, @model.ResponseHead) -> B raise) -> ResponseAs[B]
// v0.2: as_lines(f, max_line_bytes? = 1 MiB), as_both, as_form

// a request plus how to read its response (sttp Request[T]); opaque, stores per-field option overrides
pub fn[T] ClientRequest::new(raw : @model.Request, response_as : ResponseAs[T]) -> ClientRequest[T]   // (new) no options? parameter
pub fn[T, U] ClientRequest::response(self : ClientRequest[T], ra : ResponseAs[U]) -> ClientRequest[U]
pub fn[T] ClientRequest::body_fn(self : ClientRequest[T], f : () -> Bytes) -> ClientRequest[T]   // built per attempt, after admission
pub fn[T] ClientRequest::timeout_ms(self : ClientRequest[T], ms : Int) -> ClientRequest[T]       // max_body_bytes, read_idle_ms; each overrides one field of the Client's options
pub fn[T, A] ClientRequest::attribute(self : ClientRequest[T], key : @model.AttributeKey[A], value : A) -> ClientRequest[T]  // (new)
pub fn[T] ClientRequest::raw(self : ClientRequest[T]) -> @model.Request
// v0.2: ClientRequest::to_curl(sensitive_headers?); follow_redirects(Bool), max_redirects(Int) overrides

pub(all) struct Reply[T] { status : Int; headers : @model.Headers; body : T; request : @model.RequestHead; attributes : @model.Attributes }

// policy data: the single per-request channel
pub let rate_limit_bucket : @model.AttributeKey[String]
pub let global_exempt : @model.AttributeKey[Bool]
pub let operation_id : @model.AttributeKey[String]      // set by the endpoint interpreter; never used as the bucket

pub(all) struct RetryContext { request : @model.Request; bucket : String; attempt : Int; random : Double
  now_unix_ms : Int64; remaining_ms : Int64?; replayable : Bool }
pub fn RetryContext::new(request : @model.Request, attempt~ : Int, bucket? : String, random? : Double,
  now_unix_ms? : Int64, remaining_ms? : Int64, replayable? : Bool) -> RetryContext
pub(open) trait RetryDecider { decide(Self, Error, RetryContext) -> @retry.Decision }  // sees TransportError, ResponseError, declared errors, reader errors
pub(all) struct RetryPolicy { rule : @retry.RetryRule } derive(Eq, Debug)
pub fn RetryPolicy::conservative() -> RetryPolicy       // none(); (ported) default(), stainless(cap~), from_rule(r), with_max_retries(n), allow_non_idempotent()
pub impl RetryDecider for RetryPolicy
pub fn outcome_of(e : Error) -> @retry.AttemptOutcome?  // renamed from Outcome
pub(open) trait RateLimiter {
  async fn acquire(Self, String, global_exempt~ : Bool) -> Unit
  async fn release(Self, String, status~ : Int, headers~ : @model.Headers) -> Unit
}
pub fn NoLimiter::new() -> NoLimiter                     // (moved)
pub(all) struct Attempt { request : @model.RequestHead; bucket : String; attempt : Int; status : Int
  headers : @model.Headers; duration_ms : Int64; error : Error?; decision : @retry.Decision? }

// Backend + defaults + policy: sdk-runtime's Client generalised to ClientRequest[T]. The only sending path.
pub fn Client::new(
  backend : &Backend,
  clock : &@clock.Clock,
  base_url? : String,                 // joined by prefix (join_url), never RFC 3986-resolved
  headers? : @model.Headers,          // defaults; a header the request sets itself wins
  options? : RequestOptions,          // (new) client-wide defaults; default RequestOptions::default()
  retry? : &RetryDecider,             // default: no retry
  limiter? : &RateLimiter,
  timer? : &@clock.Timer,             // fallback enforcer only, for backends that ignore timeout_ms
  total_ms? : Int,                    // whole-call deadline; shrinks each attempt's timeout_ms
  observer? : (Attempt) -> Unit,
  random? : () -> Double,             // default @clock.default_random
) -> Client
pub async fn[T] Client::send(self : Client, r : ClientRequest[T]) -> Reply[T]
pub fn Client::close(self : Client) -> Unit
pub fn[T, E : Error] Paginator::with_cursor(f : async (String?) -> Page[T] raise E) -> Paginator[T, E]  // (moved; Paginator::new kept)

// v0.2 transport wrappers (structs implementing Backend; they see streams)
pub fn FollowRedirects::new(inner : &Backend, allow_downgrade? : Bool, credential_headers? : Array[String], on_redirect? : (RedirectHop) -> Unit) -> FollowRedirects // (moved)
// gaato/mttp/client/cookies (v0.2)
pub fn Cookies::new(inner : &@client.Backend, jar : @cookie.CookieJar) -> Cookies                      // (moved)
```

**Client-wide options** (v0.1, **(new)**; not in `wf3/rev`, whose `ClientRequest::new` still takes a whole `options?`). Every v0.1 consumer needs client-wide defaults: discord's `request_timeout_ms` and `MAX_RESPONSE_BODY_BYTES`, `OpenAI::new`/`Anthropic::new(timeout_ms~, total_timeout_ms?)`, and `GitHub::new(timeouts?)`. A whole `RequestOptions` stored per request cannot be merged with a client default, because `max_body_bytes : Int` cannot express "unset". So `Client::new` takes `options`, `ClientRequest` stores per-field overrides, and its setters (`timeout_ms`, `max_body_bytes`, `read_idle_ms`; `follow_redirects` and `max_redirects` at v0.2) override the Client's options field by field. `body_deadline` is always set by `Client::send`.

**Content codings** (`decompress`; RT-16, F40):

| Case | Backend behaviour |
|---|---|
| `decompress = true` (default), request without `Accept-Encoding` | Sends `Accept-Encoding: gzip, deflate, br, zstd`, undoes the codings within the §5.2 bounds, and removes the undone codings from `Content-Encoding`, and `Content-Length` with them (CONTRACT 7). An unknown coding stays on the body untouched. This is http-async's behaviour today. |
| `decompress = true`, request with its own `Accept-Encoding` | The request's value is sent, and the body comes back as sent (as today). |
| `decompress = false` | Sends the request's own `Accept-Encoding`, or `identity` when there is none, so the runtime's automatic gunzip (F40) never fires; the bytes pass through unchanged. |
| JS | fetch always negotiates and decodes; this is a per-target CONTRACT exception. |

**The Client loop.** This is sdk-runtime's hardened loop. `wf3/rev` has four client tests (`app/src/e2e/client_test.mbt`) plus the cross-layer e2e suite. Each rule says whether it is tested there; rules marked *(not yet tested in wf3/rev)* need the tests listed after the rules before v0.1.

1. **Prepare once.**
   - `url = join_url(base_url, raw.url)`; defaults are merged under the request's own headers. *(tested)*
   - The bucket is the `rate_limit_bucket` attribute, else `"default"`. The exemption comes from `global_exempt`. *(tested)*
   - The request is replayable if `body_fn` is set or the body is replayable.
2. **Each attempt.**
   - **Deadline check first.** If `total_ms` is set and no time is left, raise `TransportError(Timeout(ms=total_ms), Unknown)` without asking the decider. No attempt is made, so neither the limiter nor the observer is called. A non-positive `total_ms` therefore fails before anything is sent. A non-positive `timeout_ms` fails each attempt at once with `Timeout(ms)`, and the backend never sees a value ≤ 0. This is sdk-runtime's `check_deadline` and `Timeouts` rule. *(not yet tested in wf3/rev; its loop passes 0 or a negative `timeout_ms` to the backend)*
   - `timeout_ms = min(options or override timeout, total_ms remaining)`, and `body_deadline = !streaming`. *(`body_deadline` tested)*
   - The body is built from `body_fn`. *(not yet tested in wf3/rev)*
   - Then `acquire`, then `send`. The head is captured as soon as it arrives. *(tested)*
3. **Head rejected** (`accept_head` false): read at most 1 MiB of the body, close it, and run `reject`, which raises (`UnexpectedStatus` by default). This happens *inside* the attempt, so the decider sees error statuses even for streaming readers (I-03 fixed). *(tested)*
4. **Head accepted.** *(tested)*
   - A buffered reader runs inside the attempt, so a reader error (GitHub's GraphQL `RATE_LIMITED` in a 200) reaches the decider.
   - A streaming reader's body is read **once, after the loop**, and closed afterwards.
5. **Exactly one `release` per `acquire`.** It uses the head's status and headers whenever a head arrived, even if the reader raised later (S-12). It uses `(0, empty)` only when no head arrived. *(tested)*
6. The **observer** gets an `Attempt` after the release, including the decision on failure. *(tested)*
7. **Decision.** `Wait(ms)` sleeps on the injected clock; `Stop` raises the error unchanged. The decider receives `remaining_ms`, so a `RetryRule` stops with `Budget` instead of waiting past the end. Whatever the decider says, the loop enforces one thing: if the request is not replayable (no `body_fn`, and the body is a `Stream`), a `Wait` becomes `Stop(NotReplayable)`, and the observer sees that decision. *(not yet tested in wf3/rev; its loop only hands `replayable` to the decider)*
   - **Method gating belongs to the decider**, not the loop. In `RetryRule` it is the `Methods` setting of each status rule and of `sent_failures`, with `@model.is_idempotent` (method, Idempotency-Key or `replay_safe`) deciding `Idempotent`.
   - `conservative()` resends any method on 429 or when the failure `is_unsent`, and resends 408/409/500/502/503/504 and failures after sending only for idempotent requests.
   - `stainless()` resends any method on 408/409/429/5xx and on any failure but a protocol error, as it does today; openai and anthropic use it.
   - `wf3/rev` tests `replay_safe` with a POST 503, but its `client/retry` is a stand-in that hard-codes the method gate (§4.4, port note).
8. **Limiter waits** count against `total_ms` but are not interrupted, so every admission is paired with a release. A limiter wait can therefore overrun the total by up to its own length. *(not yet tested in wf3/rev)*
9. **Timer fallback.** `timeout_ms` is the only attempt deadline, and backends normally enforce it themselves. With `timer` set, the attempt also runs inside `Timer::within(timeout_ms)`, for backends that ignore it; expiry raises `TransportError(Timeout(ms), Unknown)`. *(tested with a timer that never finishes)*

Tests to add to `mttp/client` before v0.1:

- Port the three tests in `runtime-tests/src/retry_timeouts_test.mbt`: "an attempt that runs out of time is retried for GET, not for POST", "the total timeout caps a Retry-After or backoff wait", and "no attempt starts once the total timeout has passed".
- A custom decider that always returns `Wait`, with a `Stream` body, gives one send and `Stop(NotReplayable)`.
- `stainless()` resends a POST after a 503.
- `body_fn` is called once per attempt, after `acquire`.
- A limiter wait under `total_ms` is paired with its release.

Usage (compiled in `wf3/rev/app/src/e2e/client_test.mbt`):

```moonbit
let client = @client.Client::new(
  backend, clock,
  base_url="https://ghe.example.com/api/v3",
  headers=@model.Headers::of([("accept", "application/vnd.github+json"), ("authorization", "Bearer t")]),
  retry=GitHubRetry::{ policy: @client.RetryPolicy::conservative() },
  limiter~,
)
let reader : @client.ResponseAs[GhUser] = @client.as_bytes().map(b => {
  let j = @json.parse(@utf8.decode(b))
  if j is { "errors": _, .. } { raise RateLimitedInBody }   // decided by GitHubRetry
  @json.from_json(j)
})
let reply = client.send(@client.ClientRequest::new(
  @model.Request::post("/graphql").header("accept", "application/json").attribute(@client.rate_limit_bucket, "graphql"),
  reader,
))
// URL https://ghe.example.com/api/v3/graphql; slept [1000]; limiter saw "release graphql 200 4" for the raised 200
```

**Port note.** `client/retry` and `client/ratelimit` are **ported**, not moved verbatim. Today's `WindowLimiter::new` and `rate_limit_headers` name `@http.Headers` and `@sync.Gate`, and `RetryRule::decide` matches `HttpError` constructors. The substitutions:

| Today | mttp |
|---|---|
| `HttpError` | `TransportError`; constructor matches (`Timeout`, `Network`, …) rewritten as `Kind` matches |
| `@http.Request`, `@http.Headers` (also inside `Outcome::Response`) | `@model.Request`, `@model.Headers` |
| `@sync.Gate` | `@clock.Gate` |
| `Outcome` | `AttemptOutcome` |
| `Methods::Listed(Array[String])` | `Listed(Array[@model.Method])` |
| `@http.is_idempotent` inside the rule | `@model.is_idempotent` (adds `replay_safe`) |

The decide_test fixtures that build `@http.HttpError` change accordingly. (`Int32` in today's mbti is just how `Int` prints, so it needs no substitution.) `wf3/rev`'s `client/retry` is a stand-in: a status list, a base delay and a hard-coded idempotence gate. The real port is **[needs-prototype]**.

### 4.5 h1 (sans-IO HTTP/1.1 codec) [needs-prototype] (B-02)

Both stock server parsers (moonbitlang/async 0.22.5 and core-main) read heads and chunk-size lines with an unbounded `read_until`. Header ingest is quadratic. They keep a connection open after a request carrying both Content-Length and Transfer-Encoding, and they merge duplicate headers (F36–F39). A pre-reader in front of the stock parser works only on core-main, and can never bound chunk lines. mttp therefore owns the codec, and mttp-net only moves bytes. The client side has the same gap: the runtime client reads response heads, chunk-size lines, trailers and a proxy's CONNECT answer with the same unbounded `read_until` (RESOURCE_BOUNDS known gap). `parse_response_head` and the ChunkedDecoder are therefore also meant for AsyncBackend (later).

```moonbit
// (new) gaato/mttp/h1 — all 4 targets, tested with check_splits; imports model only
pub(all) struct Limits { max_head_bytes : Int; max_chunk_line_bytes : Int; max_trailer_bytes : Int; max_headers : Int }
#non_exhaustive
pub(all) enum ParseKind { HeadTooLarge; Malformed; Smuggling; Unsupported } derive(Eq, Debug)
pub(all) suberror ParseError { ParseError(kind~ : ParseKind, detail~ : String) } derive(Debug)
#non_exhaustive
pub(all) enum Version { Http10; Http11 } derive(Eq, Debug)
pub fn scan_head(buf : BytesView, max~ : Int) -> Int? raise ParseError   // end of head, or None = need more bytes (prototype: wf2/runtime/core/async/zz_mttp_model)
pub fn parse_request_head(head : BytesView) -> (@model.Method, String, Version, @model.Headers) raise ParseError  // duplicates kept
pub fn parse_response_head(head : BytesView) -> (Version, Int, @model.Headers) raise ParseError                  // for the client side, later
#non_exhaustive
pub(all) enum Framing { NoBody; Length(Int64); Chunked; UntilClose }
pub fn request_framing(headers : @model.Headers) -> Framing raise ParseError  // CL+TE -> Smuggling; duplicate or invalid CL -> Malformed
pub fn ChunkedDecoder::new(limits : Limits) -> ChunkedDecoder
pub fn ChunkedDecoder::feed(self : ChunkedDecoder, b : BytesView) -> Decoded raise ParseError   // bounded size and trailer lines
pub(all) struct Decoded { chunks : Array[Bytes]; done : Bool; trailers : @model.Headers; consumed : Int }  // consumed: bytes used; the rest belongs to the next pipelined request
pub fn write_response_head(status : Int, headers : @model.Headers, framing : Framing, version : Version) -> Bytes
pub fn encode_chunk(b : Bytes) -> Bytes
```

Rules:

| Case | Behaviour |
|---|---|
| `HeadTooLarge` | 431 and close |
| `Malformed` (including a missing `Host` on HTTP/1.1) | 400 and close |
| `Smuggling` | 400 and close (RFC 9112 §6.3) |
| `Unsupported` (any transfer coding other than chunked) | 501 |
| HTTP/1.0 request | Keep-alive only when asked for. The response is framed by `Length` or `UntilClose`, never `Chunked` |
| `Expect: 100-continue` | `100 Continue` is written only after the route, the security inputs and the head inputs passed. Otherwise the final status is sent and the connection closed, without reading the body |

`ParseError` takes the kind form so that it can grow without breaking matches (§5.6).

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
pub struct Head { request : @model.Request; captures : Map[String, String]; query : Array[(String, String)] }   // what an input sees before the body
pub struct RequestSink { /* private */ }                                    // (new) opaque; wf3/rev had read-only `mut` fields (E4094 outside endpoint)
pub fn RequestSink::set_header(self : RequestSink, name : String, value : String) -> Unit    // (new)
pub fn RequestSink::add_query(self : RequestSink, name : String, value : String) -> Unit     // (new)
pub fn RequestSink::set_capture(self : RequestSink, name : String, value : String) -> Unit   // (new)
pub fn RequestSink::set_body(self : RequestSink, body : @model.Body) -> Unit                 // (new)
pub(all) enum BodyValue { NoBody; Buffered(Bytes); Streamed(&@model.BodyStream) }
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
pub fn[T] attribute(key : @model.AttributeKey[T]) -> Input[T?]            // server-only: no docs, no-op on encode (SC-07)
// (new, v0.3) stream_body(media), query_params(), headers(), paths(name) for a {name...} capture, client_ip(trust_forwarded~)
pub fn[T] Input::optional(self : Input[T]) -> Input[T?]
pub fn[T, U] Input::map(self : Input[T], to : (T) -> U raise @schema.DecodeFailure, from : (U) -> T) -> Input[U]
pub fn[A, B, T] Input::map2(a : Input[A], b : Input[B], to : (A, B) -> T, from : (T) -> (A, B)) -> Input[T]  // map3..map8 generated; nest pairs beyond 8
pub fn[A, B] pair(a : Input[A], b : Input[B]) -> Input[(A, B)]

// outputs and declared errors: a variant = (status, media type, headers, codec)
pub fn[T] json_variant(status : Int, codec : @schema.BodyCodec[T], description? : String) -> Variant[T]
pub fn empty_variant(status : Int, description? : String) -> Variant[Unit]
pub fn[A, T] Variant::contramap(self : Variant[A], project : (T) -> A?, inject : (A) -> T) -> Variant[T]
pub fn[T, H] Variant::and_header(self : Variant[T], name : String, codec : @schema.TextCodec[H]) -> Variant[(T, H)]   // tapir header[T] (SC-03)
pub fn[T] Variant::fixed_header(self : Variant[T], name : String, value : String) -> Variant[T]
pub fn[T] json_out(codec : @schema.BodyCodec[T], status? : Int) -> Out[T]       // no_content, one_of(variants)
pub fn[T, H] Out::and_header(self : Out[T], name : String, codec : @schema.TextCodec[H]) -> Out[(T, H)]
// (new, v0.3) Out::and_status() (dynamic status; verified in wf2/completeness/out), set_cookie(name), text_out, bytes_out,
// a body output whose content type is computed per response (discord's multipart interaction replies carry a boundary)
pub fn[T] sse_out(codec : @schema.JsonCodec[T]) -> Out[EventStream[T]]    // (new) to_event : (T) -> SseEvent mapper, last_event_id() input
pub fn[T] EventStream::from_pull(next : async () -> T?, close : () -> Unit) -> EventStream[T]   // from_array
pub async fn[T] EventStream::each(self : EventStream[T], f : async (T) -> Unit) -> Unit
pub fn[E] Errors::new(classify : (Error) -> E?, variants : Array[Variant[E]]) -> Errors[E]
pub(all) suberror NoError derive(Debug)

// endpoints: builders never raise, so endpoints are top-level `pub let`s (unused ones are removed in release builds)
pub let endpoint : Endpoint[Unit, Unit, NoError, Unit]
pub fn[S, I, E, O] Endpoint::path(self : Endpoint[S, I, E, O], template : String) -> Endpoint[S, I, E, O]   // appends
pub fn[S, I, E, O] Endpoint::get(self : Endpoint[S, I, E, O], template : String) -> Endpoint[S, I, E, O]    // post, delete, with_method
pub fn[I, E, O, S2] Endpoint::security(self : Endpoint[Unit, I, E, O], s : Input[S2]) -> Endpoint[S2, I, E, O]   // set-once
pub fn[S, E, O, I2] Endpoint::input(self : Endpoint[S, Unit, E, O], i : Input[I2]) -> Endpoint[S, I2, E, O]
pub fn[S, I, O, E2] Endpoint::errors(self : Endpoint[S, I, NoError, O], e : Errors[E2]) -> Endpoint[S, I, E2, O]
pub fn[S, I, E, O2] Endpoint::output(self : Endpoint[S, I, E, Unit], o : Out[O2]) -> Endpoint[S, I, E, O2]
pub fn[S, I, E, O] Endpoint::operation_id(self : Endpoint[S, I, E, O], id : String) -> Endpoint[S, I, E, O]  // summary, tag, max_body_bytes
pub fn[S, I, E, O] Endpoint::rate_limit_bucket(self : Endpoint[S, I, E, O], f : (@model.Request) -> String) -> Endpoint[S, I, E, O]  // (new)
pub fn[S, I, E, O] Endpoint::doc(self : Endpoint[S, I, E, O]) -> EndpointDoc   // EndpointDoc, VariantDoc: read-only `pub` plus constructors (new), like Atom

// the one definition checker (Router::new, to_openapi and testkit.verify all call it)
pub(all) struct DefinitionProblem { template : String; message : String; fatal : Bool } derive(Eq, Debug)
pub fn check_definitions(docs : Array[EndpointDoc]) -> Array[DefinitionProblem]
pub(all) suberror DefinitionError { DefinitionError(Array[DefinitionProblem]) } derive(Debug)

// server interpreter (one endpoint; the router picks it)
#non_exhaustive
pub(all) enum FailureStage { Security; Head; Body } derive(Eq, Debug)
pub(all) struct FailureContext { request : @model.Request; endpoint : EndpointDoc; failures : Array[InputFailure]; stage : FailureStage }
pub(all) struct DispatchContext { max_body_bytes : Int; max_issues : Int
  decode_failure : (FailureContext) -> @model.Response; unhandled : (@model.Request, Error) -> @model.Response }
pub let route_template : @model.AttributeKey[String]     // set on every dispatched response
pub fn[S, I, E, O, P] Endpoint::serve(self : Endpoint[S, I, E, O], authenticate : async (S) -> P, handle : async (P, I) -> O) -> ServerEndpoint
pub fn[I, E, O] Endpoint::serve_public(self : Endpoint[Unit, I, E, O], handle : async (I) -> O) -> ServerEndpoint
pub async fn ServerEndpoint::dispatch(self : ServerEndpoint, req : @model.Request, params : Map[String, String], ctx : DispatchContext) -> @model.Response noraise

// client interpreter: relative targets, joined onto Client's base_url
pub fn[S, I, E : Error, O] Endpoint::request(self : Endpoint[S, I, E, O], security : S, input : I) -> @client.ClientRequest[O]
pub async fn[S, I, E : Error, O] Endpoint::call(self : Endpoint[S, I, E, O], client : @client.Client, security : S, input : I) -> O
pub async fn[S, I, E : Error, O, R] Endpoint::call_with(self : Endpoint[S, I, E, O], client : @client.Client, security : S, input : I, use_ : async (O) -> R) -> R
```

**Custom inputs.** `Input::new` is public so that third-party inputs (client IP, custom auth) can be written outside the package. In `wf3/rev` it could not be used from outside: `Staged[T]` had no public constructor (E4015), and `RequestSink`'s `mut` fields are read-only outside the package (E4094). `Staged::ready`/`after_body` and the `RequestSink` setters above fix both. P-01 stays "Input::new usable outside endpoint: not yet verified" until a cross-package test passes.

Client interpreter rules (verified unless marked):

- **Variant selection by (status, media type).** An empty variant matches only a response without a content type. A framework `application/problem+json` 404 is never decoded as a declared `application/json` 404; it surfaces as `UnexpectedStatus(404)` (I-02).
- **Same-status variants are tried in declaration order.** `Deserialization` is raised only if every candidate fails. In `wf3/rev`, `NotFound(Int)` and `NoTeam(String)` both live at 404 and both are reachable (SC-04).
- **Inside the attempt.** `accept_head` means "an output variant matches", and `reject` decodes declared errors and raises the user's own `E`. Both run inside the attempt, so `call_with` (streaming) is retried on 503 exactly like `call` (I-03).
- **Request attributes (new).** The encoded request carries `operation_id`. It sets `rate_limit_bucket` only when the endpoint declares `rate_limit_bucket(f)`; otherwise the bucket stays unset and the Client uses `"default"`. Real limiter users bucket by method and URL: GitHub uses `core`, `search`, `graphql`, `graphql:mutation`, `core:write` and `core:notifications` (`github/src/call.mbt`), and discord uses the route with its major parameters. An operation-id bucket would break GitHub's WindowLimiter under SDK phase 2. `wf3/rev` still uses the operation id as the bucket; its test "retry: 503 then success … observer bucket = operation id" changes with this rule.
- **Marking a call.** A request built by `Endpoint::request` is marked through `ClientRequest::attribute`, for example `client.send(@api.op.request(s, i).attribute(@model.replay_safe, true))`.
- **Sync half stays internal.** `encode_request`/`decode_response` are internal in v0.3; they become public only when a consumer (browser, Rabbita) needs them.

Known limits, documented rather than changed:

- **Set-once leaks while a slot's type is `Unit`.** `.output(no_content()).output(json_out(..))` compiles (I-07). `verify` could flag it later.
- **A base endpoint cannot share a path capture.** Each endpoint re-declares `{org}` in its own input, and the checker's message says so (I-08).
- **Unqualified constructors work only inside the defining package.** Elsewhere `raise Forbidden` and `catch { NotFound(_) => .. }` are E4021 and E4029; qualify them as `@api.Forbidden` (I-06).

Usage (compiled in `wf3/rev/app/src`; the server handlers are written as arrow lambdas, which compile and remove `unused_async` warnings, F54):

```moonbit
// definition package: imports model, schema and endpoint only; checks on wasm-gc
pub(all) suberror ApiError { NotFound(Int); Forbidden; NoTeam(String) } derive(Debug)
let api_errors : @endpoint.Errors[ApiError] = @endpoint.Errors::new(
  e => match e { ApiError::_ as a => Some(a); _ => None },
  [
    @endpoint.json_variant(404, @schema.jint.body()).contramap(e => match e { NotFound(id) => Some(id); _ => None }, id => NotFound(id)),
    @endpoint.json_variant(404, @schema.jstring.body()).contramap(e => match e { NoTeam(n) => Some(n); _ => None }, n => NoTeam(n)),
    @endpoint.empty_variant(403).contramap(e => match e { Forbidden => Some(()); _ => None }, _ => Forbidden),
  ],
)
pub let secured : @endpoint.Endpoint[String, Unit, ApiError, Unit] = @endpoint.endpoint
  .path("/api/v1").security(@endpoint.bearer()).errors(api_errors)
pub let get_user : @endpoint.Endpoint[String, GetUser, ApiError, User] = secured
  .get("/users/{id}")
  .input(@endpoint.Input::map2(
    @endpoint.path("id", @schema.int.validate(@schema.minimum(1))),
    @endpoint.query("fields", @schema.string).optional(),
    (id, fields) => { id, fields }, g => (g.id, g.fields)))
  .output(@endpoint.json_out(user_json.body()))
  .operation_id("getUser")
pub let create_user : @endpoint.Endpoint[String, NewUser, ApiError, (User, String)] = secured
  .post("/users")
  .input(@endpoint.body(new_user_json.body()))
  .output(@endpoint.json_out(user_json.body(), status=201).and_header("location", @schema.string))
  .max_body_bytes(64)

// server package (constructors qualified; Router::new raises DefinitionError)
let auth : async (String) -> String = token => if token == "secret" { "admin" } else { raise @api.Forbidden }
let router = @router.Router::new([
  @api.get_user.serve(auth, (_who, q) => {
    match store.get(q.id) {
      Some(u) => u
      None => raise @api.NotFound(q.id)
    }
  }),
])
// client: any Backend, including the Router itself in tests
let client = @client.Client::new(router, clock, base_url="http://in-process")
let user = @api.get_user.call(client, "secret", { id: 1, fields: None }) catch {
  @api.NotFound(_) => return "none"
  e => raise e
}
```

### 4.8 router

```moonbit
pub using @endpoint {type FailureContext}
pub type Middleware = async (@model.Request, async (@model.Request) -> @model.Response noraise) -> @model.Response noraise
pub(all) struct ServerOptions {
  max_body_bytes : Int                                                   // default per-endpoint limit (1 MiB); Endpoint::max_body_bytes overrides
  max_issues : Int                                                       // 100
  decode_failure : (@endpoint.FailureContext) -> @model.Response?       // None = default table
  reject : (@model.Request, Array[@model.Method]) -> @model.Response    // 404 / 405 + Allow
  on_unhandled : (@model.Request, Error) -> @model.Response?            // None = plain 500 problem; never shows details by default
  middleware : Array[Middleware]
}
pub fn ServerOptions::default() -> ServerOptions
pub fn Router::new(endpoints : Array[@endpoint.ServerEndpoint], options? : ServerOptions) -> Router raise @endpoint.DefinitionError
pub async fn Router::dispatch(self : Router, req : @model.Request) -> @model.Response noraise
pub fn Router::handler(self : Router) -> async (@model.Request) -> @model.Response noraise
pub fn Router::docs(self : Router) -> Array[@endpoint.EndpointDoc]
pub impl @client.Backend for Router
pub fn problem(status : Int, title : String, errors? : Json) -> @model.Response    // RFC 9457 problem+json
pub fn default_decode_failure(ctx : @endpoint.FailureContext) -> @model.Response
pub fn cors(allow_origins : Array[String]) -> Middleware
// (new) hide_endpoints_with_auth : (FailureContext) -> Response?   — a decode_failure preset (404 instead of 401)
// (new, v0.3) request_id(), access_log(clock, sink)
```

The pipeline. Credentials are checked first, a deliberate deviation from tapir (P-04, **[needs-user-input]**).

1. **Route** by template. Literal segments beat captures, position by position.
   - Unknown path: 404. Known path with the wrong method: 405 with `Allow`.
   - HEAD is served by GET; OPTIONS is answered automatically.
   - Once a route matches there is no fall-through.
   - A `{name...}` rest capture with the lowest specificity is decided before P-03/P-06 freeze **[needs-prototype]**.
2. **Decode the heads** of the security and regular inputs, collecting every failure up to `max_issues`.
3. **Security head failed:** answer now. Auth atoms give 401 with `WWW-Authenticate`, others 400. The body is closed unread.
4. **`raw_body` in the security input:** buffer the body now, bounded. Over the limit gives 413 with `Connection: close`.
5. **Run `authenticate`.** A classified error answers with its declared variant; anything else goes to `on_unhandled`.
6. **Regular head failures** answer 400 listing every problem (problem+json).
7. **Body:** content type (415), bounded read (413 + close) or stream handover, then decode and validate (400; 422 is P-05).
8. **Run the handler.** An output encodes as its variant; a classified error as its declared variant; anything else is a 500 without details. Every response carries the `route_template` attribute, so request-level middleware can label metrics and spans after `next` (SC-06).

**Server body limit (new).** The effective limit is `min(adapter ceiling, Endpoint::max_body_bytes or else ServerOptions.max_body_bytes)`. The adapter ceilings are `ServerLimits.max_body_bytes` (1 MiB) and `fetch_handler(max_body_bytes?)` (1 MiB, the default `wf2/runtime/shared/fetch` compiled). When the router knows the ceiling, `check_definitions` reports an endpoint override above it as an advisory problem.

**Request URL on the server (new).** Adapters put an absolute URL into `Request.url`, built from the adapter's scheme and the `Host` header (`h1`) or taken from `JsRequest.url` (fetch); Router-as-Backend already uses `http://in-process/...`. The router matches only the path.

**Router as a Backend.** The server side gets a fresh request whose attributes hold only `remote_addr = "in-process"`; the client never sees server-side response attributes (I-09, as over a socket). Bodies pass through unbuffered because both directions are pull: an SSE stream of 50 events goes through untouched, while a buffered reader with `max_body_bytes(100)` refuses with `TooLarge(limit=100)` (verified).

### 4.9 apispec and openapi (v0.4)

`apispec` is plain data with `derive(ToJson, FromJson)` and field renames (`in`, `type`, `$ref`). Its records are OpenApi, Info, Server, PathItem, Operation, Parameter, RequestBody, MediaTypeObject, ResponseObject (with `headers`), HeaderObject, Components, SecurityScheme and Tag. It depends only on core json. A comparator comes later. The objects gain `extensions : Map[String, Json]` (new).

```moonbit
pub fn to_openapi(docs : Array[@endpoint.EndpointDoc], info : @apispec.Info, servers? : Array[@apispec.Server]) -> @apispec.OpenApi raise @endpoint.DefinitionError
pub fn docs_endpoint(spec : @apispec.OpenApi, path? : String) -> @endpoint.ServerEndpoint
pub fn check_documented(spec : @apispec.OpenApi, template : String, meth : @model.Method, status : Int) -> String?
```

Projection rules (verified in `wf3/rev` unless marked):

| Concern | Rule |
|---|---|
| Statuses | One response object per status. Content is keyed by media type. Two variants with the same status and media type become `oneOf`. |
| Framework statuses | 400, 401, 404, 405, 413, 415 and 500 (and 406/422 if chosen) are added per endpoint as `application/problem+json` with `$ref: #/components/schemas/Problem`, merged into any declared status. A declared 404 and the router's 404 share one response with two media types. |
| Schemas | Component schemas are the union of every `defs`. (new) Two different definitions under one name are refused, and every `$ref` must resolve (conformance check). |
| Response headers | `Variant::and_header`/`fixed_header` names appear under `responses.<status>.headers`. |
| Security | All Auth atoms of one security input form **one** requirement object (AND). An all-optional security input adds `{}`. (new) `any_of` groups give OR; OAuth2 (flows, scopes, required scopes) and OpenIdConnect are added later. |
| Signatures | A `signature_header` atom is a required header parameter, never an invented scheme type. |
| Version | OpenAPI 3.1 only **[needs-user-input]**. |

### 4.10 testing (v0.1) and endpoint/testkit (v0.3)

```moonbit
// gaato/mttp/testing — imports model and client only, so SDK tests do not compile the endpoint layer
pub(all) suberror RunSyncError { Suspended; Cancelled } derive(Debug)
pub fn[X] run_sync(f : async () -> X) -> X raise         // %async.run + %async.capture_cancellation; refuses, never hangs
pub fn BackendStub::new() -> BackendStub                 // (moved) FakeTransport's FIFO expect/expect_stream/expect_error/assert_complete
pub fn BackendStub::when(self : BackendStub, matches : (@model.Request) -> Bool,
  respond : async (@model.Request, @client.RequestOptions) -> @model.Response raise @model.TransportError) -> BackendStub
pub fn BackendStub::sent(self : BackendStub) -> Array[@model.Request]   // replaces RecordingBackend
pub impl @client.Backend for BackendStub
pub fn[T : Eq + Debug] check_splits(input : Bytes, parse : (Array[Bytes]) -> T raise) -> Unit raise   // (moved)
pub async fn check_backend_contract(make : () -> &@client.Backend) -> Array[String]                  // (new)

// gaato/mttp/endpoint/testkit
pub fn[S, I, E, O] when_endpoint(stub : @testing.BackendStub, ep : @endpoint.Endpoint[S, I, E, O],
  respond : async (I) -> O) -> @testing.BackendStub raise @endpoint.DefinitionError   // respond may raise a declared E
pub fn verify(docs : Array[@endpoint.EndpointDoc]) -> Array[@endpoint.DefinitionProblem]  // fatal and advisory problems
```

`when_endpoint` encodes through a one-endpoint Router, so declared errors are classified as in `serve` (verified with `NotFound(9)`). Raw responses and transport failures use `BackendStub::when` directly. The intrinsics live in one file, in a package that sets `warnings = "-unused_async"` in its moon.pkg. That passes `--deny-warn` on both toolchains, but this is verified for the run_sync file only (`wf3/warnprobe`). `wf3/rev` itself does not yet pass `--deny-warn`: its `testing/moon.pkg` lacks the setting, and the whole prototype has 84 warnings (F53).

### 4.11 mttp-net (I/O adapters)

```moonbit
// backend (native, wasm, js) — v0.1
pub fn AsyncBackend::new(timeout_ms? : Int, connect_timeout_ms? : Int, write_timeout_ms? : Int, read_timeout_ms? : Int,
  pool_timeout_ms? : Int, max_connections? : Int, max_connections_per_origin? : Int, max_idle_per_origin? : Int,
  idle_max_ms? : Int, max_body_bytes? : Int, proxy? : String, trust_env? : Bool, clock? : &@clock.Clock) -> AsyncBackend   // http-async defaults kept
  // max_body_bytes: hard ceiling (moved from AsyncTransport); effective limit = min(ceiling, RequestOptions.max_body_bytes)
pub impl @client.Backend for AsyncBackend
pub fn AsyncBackend::idle_connections(self : AsyncBackend) -> Int
// codings (all 4) — v0.1
pub fn coding_plan(content_encoding : String) -> Array[Coding] raise @model.TransportError   // <= 5 codings
pub fn ContentDecoder::new(plan : Array[Coding]) -> ContentDecoder                            // 64 KiB slices
// runtime (native, wasm, js) — v0.1
pub fn AsyncClock::new() -> AsyncClock                               // impl @clock.Clock
pub fn ClockTimer::new(clock? : &@clock.Clock) -> ClockTimer         // impl @clock.Timer
pub fn SemaphoreGate::new(permits? : Int) -> SemaphoreGate           // impl @clock.Gate
pub async fn[X] with_timeout_opt(clock : &@clock.Clock, ms : Int, f : async () -> X) -> X?
pub extend AsyncClock with @clock.Clock::{sleep, now_unix_ms}        // (new) likewise ClockTimer, SemaphoreGate
pub fn VirtualClock::VirtualClock(start_ms? : Int64) -> VirtualClock // (moved) called as VirtualClock(..): 152 call sites in discord.mbt
pub async fn VirtualClock::advance(self : VirtualClock, ms : Int) -> Unit raise NoQuiescence   // (moved) advance_to_next, settle, pending, touch, next_deadline
pub(all) suberror NoQuiescence { NoQuiescence(rounds~ : Int) } derive(Debug)               // (moved)

// server (native, wasm) — v0.3, over the h1 codec; no TaskGroup in any signature
pub(all) struct ServerLimits { max_body_bytes : Int; header_timeout_ms : Int; body_timeout_ms : Int; max_header_bytes : Int
  max_connections : Int; drain_max_bytes : Int; handler_timeout_ms : Int?; drain_ms : Int }
pub fn ServerLimits::default() -> ServerLimits     // 1 MiB, 5000, 5000, 16 KiB, 256, 64 KiB, None, 10_000
pub(all) suberror ServerConfigError { InvalidMaxBodyBytes(value~ : Int); InvalidBodyTimeoutMs(value~ : Int)
  InvalidHeaderTimeoutMs(value~ : Int); InvalidMaxConnections(value~ : Int); Bind(detail~ : String); Accept(detail~ : String) } derive(Debug)  // Accept (new); frozen at release (§5.6)
pub(all) struct ServeError { kind : @model.Kind; phase : @model.Phase; detail : String }   // (new) runtime errors never escape raw
pub async fn serve(handler : @model.Handler, addr~ : String, on_listen? : (String) -> Unit, limits? : ServerLimits,
  on_error? : (ServeError) -> Unit, compression? : Bool) -> Unit raise ServerConfigError   // on_error, compression (new)

// fetch (js) — v0.3; own externs, never js_async types; host-neutral core
#external pub type JsRequest
#external pub type JsPromise
#external pub type JsBackground              // (new) a JS callback taking one promise
#external pub type JsEnv                     // (new) opaque host environment
pub let env : @model.AttributeKey[JsEnv]     // (new) optional; set only by the Workers shim
pub fn fetch_handler(handler : @model.Handler, max_body_bytes? : Int) -> (JsRequest, JsBackground) -> JsPromise
  // (new) the background argument; wf2 compiled (JsRequest) -> JsPromise with max_body_bytes? = 1 MiB
// MoonBit entry: `pub let fetch = ...` is NOT exported (verified, F20); write a function:
// pub fn fetch(req : JsRequest, bg : JsBackground) -> JsPromise { handler(req, bg) }
```

The handler calls the `JsBackground` callback **once, synchronously, at request entry**, passing one aggregate promise that settles when every task started through the `background` attribute has finished. This is the shape of discord's JS facade today (`handleRawInteraction(input, config, scheduleBackground)`, with `start_signed_interaction` returning `{response, background}` synchronously; `examples/interactions_js/handler.js`). Host entries stay small JS shims, as in discord's `examples/*_echo`:

| Host | Shim |
|---|---|
| Cloudflare Workers | `export default { fetch(req, env, ctx) }` passes `p => ctx.waitUntil(p)` and sets `env` |
| Fastly Compute | registers the promise with `event.waitUntil` synchronously, before `event.respondWith` (Fastly requires this) |
| Vercel | `waitUntil` from `@vercel/functions` |
| Deno, Bun | a tracker that keeps the promise alive (discord's `trackBackground`) |
| AWS Lambda URLs | builds a Web `Request` from the event and awaits the background promise before returning |

Behaviour:

| Area | Behaviour |
|---|---|
| Backend deadlines | `RequestOptions.body_deadline` selects http-async's `PhaseTimer::exchange` (buffered: one deadline over head and body) or `::stream` (per read, `read_idle_ms`). Content codings follow the `decompress` table in §4.4: core's client auto-gunzips only when no Accept-Encoding is sent, and raises NotImplemented for br/zstd. A request body without a length is sent chunked, so the backend sets Content-Length when it knows the length. Proxies are HTTP CONNECT only (Basic auth from the proxy URL's userinfo); there is no SOCKS. |
| Backend response parsing | The runtime client's reader parses response heads, chunk-size lines, trailers and a proxy's CONNECT answer without a byte limit; only `timeout_ms` × bandwidth bounds them (RESOURCE_BOUNDS known gap). This stays so until AsyncBackend parses responses with `h1` (`parse_response_head`, ChunkedDecoder) or upstream adds limits (risk 20). |
| Server | Configuration is validated before listening. Bind and accept failures become `ServerConfigError`. The `h1` codec reads heads within `max_header_bytes` (431). An unread body is drained up to `drain_max_bytes`, otherwise the connection is closed. Headers are validated, and responses are serialized by the codec and written raw, because the runtime's `send_response` merges duplicate headers. Responses are compressed by negotiation (v0.3). `Request.url` is absolute (scheme from the adapter, authority from `Host`). |
| Server, needs prototype | A client disconnect cancels the handler: this is new behaviour (discord's endpoint_http does not do it), easy with the own codec, which owns the buffer **[needs-prototype]**. `background` is implemented as a task in the server's group. |
| Exposure | **`mttp-net/server` never ships without `h1`** (A-03). Until discord's endpoint_http adopts `h1`, it must sit behind a proxy that limits header size, and discord's README says so. The header timeout bounds time, not bytes (F37). |
| fetch | It maps `JsRequest.signal` to handler cancellation, implements the `background` attribute by adding tasks to the aggregate promise given to `JsBackground`, and leaves `env` to the Workers shim. Prototype needed: a deferred handler outlives the response on Workers and Fastly, and Lambda awaits it before replying **[needs-prototype]**. A JS smoke test imports the built module and checks that `fetch` is exported. |

### 4.12 Codegen

- **mbt-sdk tools/gen (Python) stays.**
- **Phase 1** retargets the emitter mechanically:
  - `@http.Request::get/post/put/patch/delete(path)` becomes `@model.Request::get/post/put/patch/delete(path)` (`patch` is therefore v0.1: GitHub has PATCH operations). For any other method the emitter writes `@http.Request::new("X", path)`, which becomes `@model.Request::new(@model.Method::parse("X"), path)`; none of the three SDKs hits that branch today. `.json_body` becomes `.body_json`; `@http.append_query` becomes `@model.append_query`; `@multipart.apply(request, parts, boundary)` becomes `@multipart.body(request, parts, boundary~)`.
  - Generated `*_request` functions stay non-raising, except multipart operations. These keep `raise @multipart.MultipartError` and their explicit `boundary : String` parameter (`emit_moonbit.py` emits both today), and facades draw the boundary from injected randomness. The emitter never raises `SdkError::Config`; that comes from hand-written facade encoders (`openai/src/encode.mbt`, `anthropic/src/encode.mbt`, `github/src/graphql.mbt`), which raise `@client.InvalidRequest` instead.
  - Decoders become `*_decode(head : @model.ResponseHead, body : Bytes) -> T raise @client.ResponseError`. Facades use them as `@client.as_bytes().map_with_head((b, h) => @gen.x_decode(h, b))`. A lambda is needed: a named closed-raise function is not accepted where an open-raise one is expected (E4014), and the parameter orders differ. The raising `as_bytes()` is required so that 403/429 still reach the decider (CM-04).
  - The `@sdkjson` alias imports `gaato/mttp/jsonkit` directly, not through a shim: qualified constructors such as `@sdkjson.Value` do not resolve through `pub using` (E4021).
  - The output is regenerated, not hand-edited. The diff is large but mechanical.
- **Phase 2** (opt-in, after v0.3): Endpoint values as `pub let`. It needs header outputs (GitHub's Link and x-ratelimit-*, in 253 of 1242 operations), nesting beyond map8 (54 operations), and multipart bodies (15 operations).
- **`gaato/mttp-gen`** (attribute codegen on moonbitlang/parser) is dropped until a consumer exists. If built, it is a tool installed with `moon install` and invoked by rules, never imported (F51), with committed `*.g.mbt` output and `--check`.

## 5. Cross-cutting concerns

### 5.1 Error taxonomy

| Error | Package | Raised by | Meaning / handling |
|---|---|---|---|
| `TransportError(kind~, phase~, detail~)`, `#non_exhaustive Kind` | model | Backend::send, BodyStream::read_some, wrappers, the Client's timer fallback and deadline check, SseParser, a second take of a stream body | No usable response, the bytes did not move, or a policy refused (sttp SttpClientException). `is_unsent` gates resends. |
| `UrlError` | model | `Url::parse`, `percent_decode` | Backends map it to `Kind::Invalid`, phase Pool (unsent). |
| `ResponseError::{UnexpectedStatus, Deserialization}` | client | readers, `reject` | A response we did not want (sttp ResponseException). Error bodies are capped at 1 MiB. |
| `InvalidRequest(message~)` | client | hand-written facade encoders | The request could not be built and was never sent; replaces `SdkError::Config` at call time. |
| `MultipartError::{InvalidBoundary, BoundaryCollision, InvalidHeaderValue, StreamPart}` | multipart | `body`, `encode_segments_fresh`, generated multipart `*_request` functions | Moved unchanged; raised before anything is sent. |
| any user error | readers (`map`), deciders | user code | For example GitHub's in-body rate limit; the decider decides. |
| `DecodeFailure(kind~, message~)` / `InputErrors` | schema / endpoint | decoders | Mapped to 400/401/413/415 (422?) by the decode-failure table. |
| `UnsupportedPattern` | schema | `pattern(ecma)` | An ECMA-262 pattern outside the translatable subset; refused when the validator is built. |
| declared `E` | endpoint | handlers, `authenticate`; re-raised by `call` | Encoded as its declared variant; the client raises the same value. |
| `DefinitionError(Array[DefinitionProblem])` | endpoint | Router::new, to_openapi (fatal problems), `verify` (all) | Bad definitions are refused at construction. |
| `h1.ParseError(kind~, detail~)` | h1 | codec | 431, 400 or 501, with close. |
| `ServerConfigError` (+ Bind, Accept) | mttp-net/server | serve | Configuration and listening failures. |
| `ServeError{kind, phase, detail}` | mttp-net/server | passed to `on_error` | A value, not raised; runtime error identities never escape. |
| `RunSyncError::{Suspended, Cancelled}` | testing | run_sync | The computation needed a real event source. |
| `NoQuiescence(rounds~)` | mttp-net/runtime | `VirtualClock::advance`, `advance_to_next`, `settle` | Moved from http-async/mock: the simulated tasks never settled. |

SDK public signatures become open-raising (`raise`), and helpers take `Error` (`status_of`, `UnexpectedStatus` body). Cancellation is never converted into another error, and no test asserts on `detail` text, which differs across runtimes.

### 5.2 Resource bounds

All byte limits are `Int` (≤ 2 GiB); lengths are `Int64`.

| Bound | Default | On overflow |
|---|---|---|
| Buffered client body (`max_body_bytes`), after decoding | 64 MiB | `TooLarge`, phase Body, at the crossing chunk |
| Error body kept in `UnexpectedStatus` | 1 MiB | truncated for the error value only |
| SSE event | 16 MiB | `TransportError(kind=TooLarge(limit), phase=Body)` |
| Line reader (v0.2) | 1 MiB | `TransportError(kind=TooLarge(limit), phase=Body)` |
| Client response head, chunk-size line, trailers, proxy CONNECT answer (AsyncBackend over the runtime client) | **unbounded today** (RESOURCE_BOUNDS known gap); only `timeout_ms` × bandwidth bounds them | — (risk 20) |
| Redirect hops (v0.2) | 10 | `TooManyRedirects`; each 3xx body closed unread |
| Content codings | ≤ 5, 64 KiB slices, window caps as http-async | Protocol |
| Cookies (v0.2) | 50 per domain, 3000 total, 4096 B, 400 days | dropped per RFC 6265 |
| Retries | per preset (conservative: 2) and `total_ms` | stop with StopReason |
| Server request body | `min(adapter ceiling, endpoint override or router default)`; router default 1 MiB; ceilings: ServerLimits 1 MiB, fetch_handler 1 MiB | 413 + `Connection: close` |
| Client body ceiling (AsyncBackend `max_body_bytes?`) | none unless set; discord sets `MAX_RESPONSE_BODY_BYTES` | `TooLarge`, phase Body; effective limit is the smaller of ceiling and `RequestOptions.max_body_bytes` |
| Server head (h1) | 16 KiB | 431 + close |
| Chunk-size line / trailers (h1) | 4 KiB / 16 KiB (new) | 400 + close |
| CL+TE, duplicate or invalid CL (h1) | rejected | 400 + close |
| Server header / body timeout | 5 s / 5 s | 408 + close |
| Connections | 256 | not accepted |
| Drain of an unread body | 64 KiB | close instead |
| Query pairs / path segments | 256 / 64 | 400 / 404 |
| Issues collected per request | 100 | truncated with a marker |
| Multipart (later) | 128 parts, 8 KiB part headers, per-part limit | 413 |
| JSON nesting depth | **unbounded today** (risk 14) | — |

### 5.3 Time and randomness

Every policy takes `&@clock.Clock`, and where needed `&@clock.Timer`, `&@clock.Gate` and `random : () -> Double`: the Client loop, CookieJar, WindowLimiter, the multipart boundary, access logs and the server. Tests use `FakeClock` (immediate sleep, recorded delays) with `run_sync`; runtime tests use `VirtualClock`.

### 5.4 Streaming, SSE and WebSockets

- **One direction: pull.** Bodies are pull `BodyStream`s in both directions, so the CONTRACT rules and the conformance harness stay single.
- **Server SSE.** A handler returns an `EventStream[T]` built with `from_pull`. The endpoint encodes it as `Body::Stream`; the adapter writes it with backpressure; Router-as-Backend passes it through unbuffered (verified).
- **No push bodies.** A producer-style handler bridges through a runtime queue in the application. `ServerBody::Push` and the runtime-free push→pull bridge (old X-05) are gone.
- **Client SSE.** `as_sse` reads through the moved parser. A `stop` predicate handles non-JSON sentinels such as OpenAI's `data: [DONE]` (new).
- **WebSockets** are deferred beyond v0.3.
  - No current consumer uses them through gaato/http; discord's gateway keeps its own client.
  - When added: a 101 Response carrying the upgrade callback in an attribute (so the Handler type does not change), a sans-IO frame codec in mttp, `WebSocketStub` in testing, and scheme validation before any runtime call (a runtime client given a URL without `ws://` or `wss://` aborts the process).

### 5.5 Target matrix

| Unit | wasm-gc | wasm | js | native |
|---|---|---|---|---|
| all of gaato/mttp (incl. `h1`, async tests via `run_sync`) | ✓ | ✓ | ✓ | ✓ |
| mttp-net/codings | ✓ | ✓ | ✓ | ✓ |
| mttp-net/backend, runtime, facade | – | ✓ (moonrun, experimental) | ✓ (request bodies buffered, ≤ 16 MiB) | ✓ |
| mttp-net/server, files | – | ✓ | – | ✓ |
| mttp-net/fetch | – | – | ✓ | – |

CI lists packages per target and **asserts the test count per target**. Workspace-wide runs silently skip restricted packages, and `async test`s report 0 (or count a failing async test as passed) on wasm-gc (F16).

### 5.6 Churn policy

- **Toolchains.** Pin with `moonbit-version` (0.10.16 today). Run daily canaries on the latest toolchain (0.10.17: `try?` removed, `method` warns) and on core-main (async built from a core checkout, F41).
- **Warnings.** Run deny-warn with `warnings = "-implicit_impl_as_method"`; the `run_sync` package adds `-unused_async`. Pass arrow lambdas to async-typed parameters: `async fn` literals that never await warn `unused_async`, and arrow lambdas cannot take an `async` prefix. `wf3/rev` does not meet this yet (84 warnings, F53): six library `async fn` literals (`client/response_as.mbt`, `endpoint/output.mbt` ×2, `endpoint/server.mbt`, `endpoint/testkit/testkit.mbt`, `openapi/openapi.mbt`; the seventh, in `testing/run_sync.mbt`, is covered by the package setting), deprecated forms and unused imports must be fixed before Stage 0 exits.
- **Deprecations in both toolchains** (seen in `wf3/rev`): `Map::new()` (use `Map([])`), `.to_json()` on literals (use `Json(v)`), `StringView::to_string` (use `to_owned`), Show for debugging (use Debug), `to_array`. The generators emit the new forms.
- **Snapshots.** Keep mbti snapshots per package. Build mttp-net's private implementation against both runtimes and diff the generated mbti (F34).
- **Containment.** Runtime API churn stays in mttp-net (`internal/io`). Intrinsic churn stays in one file in `testing`.
- **Evolution rules (v0.1 onwards).**
  - **(a) Enums.** `#non_exhaustive` goes on Body, Method, Kind, Phase, `@retry.Decision` (not `#non_exhaustive` today), DecodeKind (v0.3), AuthScheme, Location, FailureStage, h1 Framing, ParseKind and Version, and on any later enum that may grow.
  - **(b) Structs.** Downstream code builds `pub(all)` structs through `::new`/`::default()` plus record update: adding a field breaks struct literals (E4044) but not record updates. Their field sets are frozen at the release that ships them:
    - v0.1: Request, Response, RequestHead, ResponseHead, RequestOptions, RetryContext, RetryPolicy, Attempt, Reply, SseEvent, multipart Part, RetryRule and its records (Backoff, RetryAfter, StatusRule), GlobalWindow, Pace, RateLimitState, Page.
    - v0.3: DispatchContext, FailureContext, DefinitionProblem, InputFailure, Schema, Issue, h1 Limits and Decoded, ServerLimits, ServerOptions.
    - v0.4: apispec records (Info and the rest).
  - **Read-only instead of frozen.** Atom, VariantDoc and EndpointDoc are read-only `pub` with constructors, because their docs fields will grow (examples, deprecated, default, extensions; SC-13). `wf3/rev`'s EndpointDoc already carries `segments`, `info` and `method_set_twice`.
  - **(c) Suberrors.** A suberror cannot be made non-exhaustive: `#non_exhaustive` on a suberror only warns (0043), a downstream exhaustive `catch` compiles, and adding a constructor then breaks it (F3, F52). A suberror that may grow therefore takes TransportError's form, one constructor carrying a `#non_exhaustive` kind enum: DecodeFailure(kind~, message~) and h1 ParseError(kind~, detail~). Every other suberror is frozen at release, and adding a constructor to one is a breaking change: ResponseError, InvalidRequest, MultipartError, UnsupportedPattern, InputErrors, DefinitionError, RunSyncError, NoQuiescence, and ServerConfigError with Bind and Accept.
  - **Opaque structs.** `Out`, `Variant`, `ResponseAs`, `Input`, `ClientRequest`, `Staged` and `RequestSink` can change internally without breaking. For example, passing the request's Accept header into output encoding (406, SC-10) is non-breaking later.

### 5.7 Testing and conformance

| Suite | Where | What |
|---|---|---|
| In-module | every gaato/mttp package | `run_sync` on all 4 targets: the Client loop, readers, router, interpreters, retry with FakeClock |
| Cross-layer gate | `mttp/conformance` | The `wf3/rev` e2e suite: definition package → Router → `Endpoint::call` through `Client`. Covers 200/400/401/403/404/405/413/415/500, retries, SSE, `when_endpoint` and OpenAPI. |
| Corpora | `mttp/conformance` | SSE, http-state cookies and WPT URL (moved from `mbt-sdk/conformance`, whose jsonrpc corpus stays), multipart reader, form decoding, router path matching, **h1 codec via check_splits**, **ECMA pattern translation**, `$ref` resolution |
| Endpoint properties | `mttp/conformance` | Client encode then server decode is the identity (server-only atoms excluded); malformed input gives a 4xx, never a 5xx; encoded samples validate against the documented schema |
| Streaming conformance | `mttp/conformance` | OpenAI SSE port (`wf2/consumer-migration/cm/src/openai_stream`); `total_ms` with streams (new) |
| Sockets | `mttp/net-tests` | http-async loopback, phase, pool, proxy, coding and upload suites on native and wasm, and its JS suites (`upload_js_test`, `proxy_js_wbtest`, `failure_js_wbtest`) on js; badhttp replays; the Backend contract against AsyncBackend and fetch |
| Adversarial | `mttp/net-tests` | Server: header-line flood (RSS and CPU), chunk-line flood, 32-connection slowloris, CL+TE smuggling, oversize body, drain. Client: a hostile server or proxy sending an endless response head or chunk-size line to AsyncBackend. Slow-drip buffered body against the exchange deadline |
| Release | CI | `moon check --deny-warn` on all 4 targets with both toolchains; resolver gate outside moon.work (§5.8); per-target test counts; paired-runtime mbti diff; JS export smoke test |

### 5.8 Versioning and release

Facts the rules rest on (F26–F33): moon selects, per module, the **highest of the declared minimums**, not the newest published version. moon.mod accepts only plain `X.Y.Z` minimums. All 0.x and 1.x versions share one compatibility set; only a new path (`/v2`) can coexist. Deprecation applies to the whole module, is advisory, and does not affect selection; there is no per-version yank (the index records a deprecation as `yanked: true` plus `yanked_reason` on every version that exists at that time). Workspace members override requirements.

| Rule | Why |
|---|---|
| A patch or security fix reaches dependents only when they raise their minimum. Every gaato dependent raises it in the same train, and the fix is announced. | MVS never upgrades on its own (F26). |
| No breaking 0.x release is "contained". A breaking minor breaks every graph in which something requires it. gaato/http never gets a 0.6. | One compatibility set (F28). |
| `gaato/mttp/v2` is reserved as the escape hatch. | Only a new path coexists (F28). |
| **mttp ↔ mttp-net compatibility** **[needs-user-input: option]**. Option 1 (proposed): each mttp minor still compiles the previous mttp-net minor (the surface mttp-net uses — model, client Backend/RequestOptions, clock — is frozen for one minor). Option 2: every mttp minor gets an mttp-net patch, and consumers require both. | "Lockstep minors" cannot be enforced; an app can resolve new mttp with old mttp-net (F29, R-07). |
| **Resolver gate:** each published module is resolved and built from a scratch consumer outside moon.work (the fake-registry harness in `wf2/resolver/tools`). A ledger check compares manifest imports with the index entry of the same version, and a version is bumped whenever moon.mod imports change. | Workspace members hide real resolutions; mbt-sdk and discord.mbt already drifted (local sdk-runtime 0.7.0 imports http 0.5.0 while the registry's 0.7.0 requires 0.4.1; local discord_voice 0.3.1 imports discord 0.13.0 while the registry's 0.3.1 requires 0.12.0) (F30). The gate covers the mttp, mbt-sdk and discord.mbt modules. |
| Deprecation is advisory and module-wide. Deprecate a module only after its last gaato dependent moved. Publish nothing to a module after deprecating it (later versions start undeprecated). | F27 |
| No moon.mod lists `gaato/mttp-gen`. | Imports are module-wide; parser drags async and x (F51). |

### 5.9 Naming

| Rule | Reason |
|---|---|
| The field is `meth` | `method` is reserved and warns on 0.10.17 |
| `input`/`output`/`security`/`errors` builders | `in` is a keyword |
| `ignore_body`, never `ignore` | shadows the prelude and breaks generated test drivers |
| `router` (not `server`) in mttp; `endpoint/testkit` (not `testing`); `jsonkit` (not `json`) | duplicate package aliases warn |
| `Reply[T]` for the typed client result | avoids two `Response` types |
| `@retry.AttemptOutcome` | avoids a third "Outcome" |
| HEAD requests via `Request::new(Head, url)` | `Request::head()` is the head accessor |
| No "tapir" or "sttp" names in the API | the family is mttp |
| Module names `gaato/mttp`, `gaato/mttp-net` **[needs-user-input]** | — |

### 5.10 Mechanisms removed from earlier drafts

| Removed | Replacement |
|---|---|
| `PartialRequest`, `RequestBuilder` trait + `pub extend`, `basic_request`, `WebSocketRequest` | `@model.Request` builders + `ClientRequest::new` + `Client` defaults |
| `Policy` as a separate value; `ClientRequest::send(backend, policy?)` | `Client` (backend + defaults + policy); `Client::send` |
| `layer` | `from_fn` |
| `as_*_always`, `as_either` | `ResponseAs::any_status`, `from_head`, `ResponseAs::new(reject~)` |
| `ReadMode` | `streaming : Bool` on the accepted body |
| `Policy.attempt_ms` next to `RequestOptions.timeout_ms` | one attempt deadline; Timer as fallback enforcer |
| `bucket_of` and the operation-id fallback | the `rate_limit_bucket` attribute. Per-request bucket computation (the old `bucket_of`) lives on the endpoint (`Endpoint::rate_limit_bucket(f)`) or in the facade, never in the Client |
| `ServerBody::Push`, `EventStream::from_producer`, X-05 bridge | pull-only bodies |
| `ServerResponse`, `ServerBody`, `Outcome` | `@model.Response` both ways; `Connection: close` |
| `RouteError`, `EndpointDefinitionError`, separate `verify` logic | `check_definitions` + `DefinitionError` |
| `raw_body(max_bytes?)`, five body-limit knobs | four knobs with one precedence: `min(adapter ceiling, endpoint override or router default)` (§4.8) |
| A whole `RequestOptions` per request (`ClientRequest::new(.., options?)`) | Client-wide `options` plus per-field overrides on `ClientRequest` |
| `fetch_handler` shaped like Workers (`(req, env, ctx)`) | host-neutral `(req, background)` plus JS shims per host |
| `serve_result` | wrap a non-Error `E` in a suberror |
| `RecordingBackend` | `BackendStub::sent` |
| `ChallengeScheme`, `ChallengeAuth`, `mttp-net/digest` (moonbitlang/x) | dropped from core; requesto keeps Digest if it survives |
| Two facades (`quick` and requesto) | exactly one (M-06) |
| `gaato/clock`, `gaato/jsonkit` modules; the forward `gaato/http` 0.5.1 shim | packages of gaato/mttp; G-02 |

## 6. sttp/tapir concept map

| sttp / tapir concept | mttp home, or the reason it is omitted |
|---|---|
| sttp-model Uri, UriInterpolator | `model.Url` (WPT parser) + string targets; `UriBuilder`/`UriPart` at v0.2 |
| Method, StatusCode, Header(s), MediaType, Request/ResponseMetadata | `Method`, Int status + helpers, `Headers`, `MediaType` (v0.3), `RequestHead`/`ResponseHead` |
| Part, ServerSentEvent, CookieWithMeta | `multipart`, `sse`, `cookie` |
| sttp-shared MonadError, F[_], Streams capability | omitted: direct-style async, one `BodyStream` |
| sttp-shared AttributeMap | `model.Attributes` (typed keys) on Request and Response |
| client4 PartialRequest / Request / RequestBuilder; basicRequest | `@model.Request` builders + `ClientRequest[T]`; Client defaults replace the template value |
| quickRequest / simple client | one facade at v0.2 (M-06) |
| ResponseAs: asString, asJson, asEither, fromMetadata, ignore, asStream*, asBoth, asParams, asFile | `as_string`, `as_json`, `ResponseAs::new(reject~)`, `from_head`, `ignore_body`, `as_stream`; `as_both`, `as_form` (v0.2); `as_file` (later, mttp-net) |
| Backend / StreamBackend / SyncBackend | `Backend` (always streams); no sync split |
| WebSocketBackend, WebSocketStub | later (§5.4) |
| RequestOptions, maxRedirects, redirectToGet | `RequestOptions` (Client-wide, with per-request overrides on `ClientRequest`); `FollowRedirects` (v0.2) |
| compressBody / compression | decoding: `mttp-net/codings` (v0.1); request compression later |
| SttpClientException / ResponseException | `TransportError` / `ResponseError` |
| FollowRedirectsBackend | `FollowRedirects` (v0.2; final URL and history as response attributes) |
| DigestAuthenticationBackend | omitted from core (requesto-only, if kept) |
| ResolveRelativeUrisBackend | `Client` base_url (prefix join, not RFC 3986) |
| ListenerBackend, LoggingBackend, OTel/Prometheus | `Client` observer (per attempt) + `from_fn`; `on_attempt_start`, header redaction helper later |
| CachingBackend | later, as a bounded Backend wrapper, or an explicit omission |
| RetryWhen, resilience | `RetryDecider` over the decoded outcome + `client/retry` + the Client loop |
| EitherBackend, TryBackend, MappedEffectBackend | omitted: they exist only for F[_] |
| BackendStub / RecordingBackend | `testing.BackendStub` (`sent` replaces RecordingBackend) |
| ToCurlConverter | `ClientRequest::to_curl` (v0.2) |
| Proxy (HTTP/SOCKS) | AsyncBackend: HTTP CONNECT only |
| tapir Endpoint, EndpointInput/Output/IO | `Endpoint`, `Input` (atoms + staged), `Out`/`Variant` |
| ParamConcat, `.in(a).in(b)` | set-once builders + map2..map8; nest pairs beyond 8; a derived input later |
| path DSL, paths (rest) | OpenAPI templates + typed `path`; `{name...}` + `paths(name)` [needs-prototype] |
| header / setCookie / statusCode outputs, emptyOutputAs | `and_header`, `fixed_header` (verified); `and_status`, `set_cookie` (v0.3) |
| extractFromRequest, clientIp, queryParams, headers | `attribute(key)` (verified); `client_ip`, `query_params()`, `headers()` (v0.3) |
| Codec, Schema, Validator, Schema.derived, SRef | `schema` package; `recursive`; mttp-gen later |
| oneOfUsingField / discriminator | `tagged` + `case_` (verified in `wf2/completeness/schema/src/fix/union.mbt`) |
| DecodeResult | raised `DecodeFailure`/`InputErrors` |
| oneOf / oneOfVariant | `Errors` (classify) + `Variant::contramap`; same status tried in order |
| oneOfBody, NotAcceptableInterceptor (406) | later; non-breaking because `Out` is opaque |
| serverLogic / serverSecurityLogic / PartialServerEndpoint | `serve` / `serve_public` + classify; no PartialServerEndpoint type |
| serverLogicRecoverErrors | `serve` (errors are raised and classified) |
| ServerInterpreter | `ServerEndpoint::dispatch` + `Router` (credentials-first deviation) |
| DecodeFailureHandler / RejectHandler / ExceptionHandler | `decode_failure` / `reject` / `on_unhandled` (returns a Response) |
| hideEndpointsWithAuth | `hide_endpoints_with_auth` preset (new) |
| RequestInterceptor / EndpointInterceptor, metrics | `Middleware` + the `route_template` response attribute; `on_body_end` later |
| CORS interceptor | `cors` middleware |
| SttpClientInterpreter | `Endpoint::request` / `call` / `call_with` |
| TapirStubInterpreter / sttp-stub4-server | `impl Backend for Router` + `testkit.when_endpoint` |
| EndpointVerifier | `testkit.verify` (= `check_definitions`) |
| OpenAPIDocsInterpreter / sttp-apispec / Comparator | `openapi.to_openapi` / `apispec` (v0.4) / comparator later |
| Examples, docs extensions, Input default, deprecated params, docs UIs (swagger, redoc) | later (SC-13) |
| auth.bearer/basic/apiKey; oauth2; openIdConnect | `bearer`, `signature_header` (+ basic/api keys v0.3); OAuth2/OIDC later |
| multipartBody (client and endpoint) | client: `@multipart.body` (v0.1); endpoint multipart later |
| static files (files module) | later: `mttp-net/files` + sans-IO conditional/Range helpers |
| streamBody / serverSentEventsBody / webSocketBody | `stream_body` / `sse_out` + `EventStream` / later |
| server backends (netty, jdkhttp), serverless | `mttp-net/server` (over `h1`), `mttp-net/fetch` (host-neutral core, JS shims for Workers, Fastly, Vercel, Deno, Bun and Lambda URLs) |
| openapi-codegen | mbt-sdk tools/gen (Python) |
| AsyncAPI | omitted for now **[needs-user-input]** |
| per-integration modules (zio, cats, circe, ...) | omitted: one runtime, one JSON |

## 7. Staged scope

Today's four modules expose 76 public types; the first architecture would have exposed about 149. Each tier below is additive on top of unchanged lower tiers. That additivity was verified by adding an endpoint layer to an unchanged v0.1 model and client (`wf2/scope/v01`), and the revised prototype is built the same way.

| Tier | Ships | Moves | What it unblocks |
|---|---|---|---|
| **v0.1** (mttp 0.1 + mttp-net 0.1) | mttp: clock, clock/fake, jsonkit, model (incl. `Request::patch`), sse (parser), multipart (writer), client (+retry, +ratelimit; Client-wide `options`, deadline rules, take-once streams), testing. mttp-net: backend, codings, runtime | discord REST (+ discord_voice, discord-cli), openai, anthropic, github (phase 1), codex-protocol; kbbi if chosen (Q16) | All client consumers |
| **v0.2** | FollowRedirects (final URL/history attributes), client/cookies + cookie, as_lines, as_both/as_form, to_curl, UriBuilder; one facade. `h1` if Q9 (c) is chosen | requesto users (or its deprecation); discord's endpoint_http onto `h1` (Q9 (c)) | requesto parity |
| **v0.3 (experimental)** | h1 (unless shipped at v0.2), schema, endpoint, endpoint/testkit, router, mttp-net/server, mttp-net/fetch; header outputs; attribute/client_ip/query_params inputs; tagged unions; ECMA patterns; SSE writer | discord interactions (Endpoint + serve + fetch_handler) | The tapir half, validated by one real consumer |
| **v0.4** | apispec, openapi, docs_endpoint, check_documented | SDK phase 2 (opt-in) | Docs from code |
| **Later, on demand** | WebSockets, multipart reader + endpoint multipart, static files, content negotiation (406), OAuth2/OIDC security, docs UI, caching backend, request compression, file bodies, mttp-gen, sync client half as public API, HTTP/2, AsyncAPI | — | — |
| **Dropped** | PartialRequest/RequestBuilder, Policy-as-value, layer, `_always` twins, as_either, ReadMode, ServerBody/Push/Outcome, serve_result, RecordingBackend, ChallengeAuth/Digest in core, quick-and-requesto both, gaato/clock and gaato/jsonkit modules, the forward shim, DeadlineTransport | — | — |

What is lost by staging: "one definition, both sides" and OpenAPI-from-code are not shipped before v0.3/v0.4; requesto users stay on the 0.5.x stack until v0.2.

## 8. Migration plan

### 8.1 Stages

| Stage | When | Steps | Exit criteria |
|---|---|---|---|
| **0** | now (0.10.16; no runtime) | Populate the existing `gaato/mttp` repository (github.com/gaato/mttp exists with no commits; `/home/user/mttp`): moon.work with mttp, mttp-net, conformance, net-tests; gates and scripts from mbt-sdk. Build the v0.1 packages of gaato/mttp. Move the HTTP corpora (SSE, WPT URL, cookies) from `mbt-sdk/conformance` into `mttp/conformance`; jsonrpc's corpus stays. **Publish nothing yet.** | Moved tests green on 4 targets through run_sync; the client-loop tests of §4.4 added; `moon check --deny-warn` on all 4 targets with both toolchains (rewrite the six library `async fn` literals as arrow lambdas, replace the deprecated forms of §5.6, drop unused imports); ledgers re-pointed; mbti reviewed |
| **1** | now (moonbitlang/async 0.22.5) | Build **gaato/mttp-net** (backend, codings, runtime). net-tests: http-async's suites against AsyncBackend on native, wasm and js (including the JS upload, proxy and failure suites); slow-drip buffered body against the exchange deadline. **Publish gate:** discord REST and openai compile and pass against mttp and mttp-net as moon.work path members (an mbt-sdk branch and a discord.mbt branch whose moon.work points at the mttp checkout). Only then publish **gaato/mttp 0.1** and **gaato/mttp-net 0.1**, because under F28 any API fix found while porting would otherwise be a breaking 0.2. | Suites green; paired-runtime mbti diff clean; publish gate passed; resolver gate passes for both published modules |
| **2** | after 1 | **Consumers onto v0.1.** SDK phase 1 (openai, anthropic, then github, about 243k lines); codex-protocol → `mttp/jsonkit`; **discord 0.14** REST, clocks, limiter, paginator; **discord_voice** re-released (http-async → mttp-net/runtime; required anyway, because it depends on discord); **discord-cli** re-released on discord 0.14; **kbbi** if chosen (Q16). runtime-tests: client-loop tests move in-module. Optional: **gaato/http 0.5.1** with a `bridge` package (Backend → Transport, buffered; streaming [needs-prototype]) for apps that mix discord 0.13 with new SDKs. | Each consumer's tests green; resolver gate from scratch consumers |
| **3** | after 2 | **v0.2**: requesto parity; M-06 decided; requesto 0.3 facade or deprecation. If Q9 (c) is chosen: `h1` ships in mttp 0.2 and discord's endpoint_http reads heads and chunked bodies through it on raw Tcp. | requesto's feature list mapped (§8.5); with Q9 (c), the adversarial server probes pass against discord's endpoint_http |
| **4** | v0.3 | **Endpoint layer (experimental) + h1 + server + fetch.** The discord interactions route becomes an Endpoint; `@server.serve` replaces endpoint_http; the host-neutral `fetch_handler` plus host shims replace the JS facade. | Adversarial probes pass against `h1`; a deferred handler outlives the response on Workers and Fastly, and Lambda awaits it before replying |
| **5** | v0.4 | apispec/openapi; optional SDK phase 2. | `check_documented` and `$ref` resolution green |
| **R** | when a released, pinned toolchain ships `moonbitlang/core/async` | **Flag day per application graph** (the runtimes cannot coexist, F35). One train switches mttp-net, discord, discord_voice, discord-cli, jsonrpc-async, codex-app-server, requesto (tests), kbbi (if migrated), examples and any remaining runtime-tests. Every app and test package using `async fn main` / `async test` changes its own moon.mod and moon.pkg import from `moonbitlang/async` to core async. Apply principle 9 to jsonrpc-async and codex-app-server first if their APIs should survive (today they expose `@async.TaskGroup[X]` and `&@io.Reader`/`Writer`). **Old-stack graphs** (anything still holding http-async 0.5.x or 0.4.x: requesto 0.2, kbbi 0.1, discord ≤ 0.13, discord_voice ≤ 0.3) cannot link with a post-R mttp-net. Either **(a)** release an http-async 0.5.(n+1) on core async — its public API names no runtime type (its mbti imports only gaato/http, http/clock and http/sync), so the API is unchanged, but under F26 apps that mix old-stack libraries with post-R mttp-net must require that version explicitly, and kbbi (on the 0.4 line) is covered only if it also builds against 0.5 — or **(b)** declare old-stack graphs frozen before Stage R and document the duplicate `pool` link error as the symptom **[needs-user-input, Q15]**. | Canary (core-main checkout) green before; per-target test counts unchanged |
| **6** | after the last gaato consumer moved | Deprecate gaato/http, http-async, sdk-runtime (and requesto if chosen); module-wide, advisory. runtime-tests dissolved. No yanks. | — |

Order note: Stage R is independent of Stages 3–5 and may come earlier. It changes every consumer manifest, which is why the runtime-free signatures matter only for API text, not for manifests.

### 8.2 gaato/http 0.5.0 → gaato/mttp

| Today | mttp |
|---|---|
| `Request{http_method : String, url : String, headers (mutable), body}` | `@model.Request{meth : Method, url : String, headers (immutable), body, attributes}` with builders |
| `Response{status, headers, body : Bytes}`, `ResponseHead` | `@model.Response` (pull `Body`) / `ResponseHead`; buffered reads via `as_bytes()` |
| Url, UrlError, ipv6, utf8 | `@model`, unchanged; plus `join_url`, `encode_path` |
| Body / StreamBody / BodyStream / TakenStream | `@model.Body` (Empty / Bytes / Stream) / `BodyStream`; TakenStream → the take-once cell inside `Body::Stream`; StreamBody's Eq (identity) and Debug → `impl Eq`/`Debug for Body` |
| Transport (send, send_stream) | `@client.Backend` (one send + RequestOptions) |
| Middleware, send_with | Backend wrappers / `from_fn` |
| follow_redirects(_stream), RedirectHop, plan_redirect | `@client.FollowRedirects` (v0.2; plan_redirect moved) |
| HttpError, RedirectError, Phase | `TransportError(kind, phase, detail)`, `Phase` |
| retry_after_ms, parse_link_next, form_urlencode, percent_*, http_date, is_idempotent, append_query | `@model` (http_date and percent_decode made public) |
| clock, sync, random | `@mttp/clock` (same names and signatures, new trait identity) |
| mock.FakeClock / FakeTransport, MockError | `@mttp/clock/fake` / `@testing.BackendStub` (same expect API + when) |
| cookie (+ cookies middleware) | `@cookie` / `@client/cookies.Cookies` (v0.2) |
| multipart (`apply(req, parts, boundary)`, MultipartError, `encode_segments_fresh`) | `@multipart` (`body(req, parts, boundary~)`, same errors, `encode_segments_fresh` kept) |
| retry | `@client/retry` (ported; substitution table in §4.4) |
| sse (each_event; `SseParser` raising HttpError) | `@sse` (raising TransportError) / `as_sse` |

### 8.3 gaato/http-async 0.5.0 → gaato/mttp-net

| Today | mttp-net |
|---|---|
| AsyncTransport (send / send_stream) | `@backend.AsyncBackend` (same options, including `max_body_bytes` as a hard ceiling); buffered vs streaming deadline from `RequestOptions.body_deadline` |
| DeadlineTransport | dropped: `timeout_ms` + Client `total_ms` |
| AsyncClock, ClockTimer, SemaphoreGate, with_timeout_opt; mock.VirtualClock (constructor `VirtualClock(start_ms?)`), NoQuiescence | `@runtime`, same constructor form and errors |
| content_coding / content_decoder | `@codings` (public) |
| loopback suites | `mttp/net-tests` |

Implementation changes at Stage R (from the paired builds): `read_some(max_len)` → `read_into(buf, max_len)`; `URIParseError` → `UriParseError`; `TaskGroup[X]` → `TaskGroup` and `return_immediately(x)` → `return_immediately()`; generic `with_task_group` in the clock code. The full rename list is in F42.

### 8.4 gaato/sdk-runtime 0.7.0 → gaato/mttp/client

| Today | mttp |
|---|---|
| `Client::new(transport, clock, base_url, default_headers, auth, retry, limiter, middleware, observer, random, timeouts)` | `@client.Client::new(backend, clock, base_url?, headers?, options?, retry?, limiter?, timer?, total_ms?, observer?, random?)`; auth becomes a default `Authorization` header; middleware becomes a Backend wrapper (`from_fn`) |
| `Timeouts{timer, attempt_ms, total_ms}` | `Client::new(timer?, options.timeout_ms, total_ms?)`; the deadline rules (no attempt after the total, non-positive limits fail at once, `remaining_ms` to the decider) are kept (§4.4 rules 2 and 7) |
| base_url (prefix join) | `Client` base_url with the same prefix semantics (`join_url`) |
| send / send_json / send_stream | `Client::send` with `as_bytes` / `as_json` / `as_stream` |
| accept hook | `ResponseAs::map` raising inside the attempt, or `ResponseAs::new(reject~)` |
| body thunk | `ClientRequest::body_fn` |
| bucket~ / global_exempt~ | `rate_limit_bucket` / `global_exempt` attributes |
| SdkError::Transport / Status / RateLimited / Decode | `TransportError` / `UnexpectedStatus` (+ `retry_after_ms`) / `Deserialization` or the reader's own error |
| SdkError::Config | `@client.InvalidRequest` (call time) |
| classify | `as_*` readers (1 MiB error-body bound kept) |
| RetryPolicy, RetryDecider, RetryContext (::new) | `@client` (decide takes Error; `RetryContext::new` kept) |
| RateLimiter, NoLimiter | `@client` |
| WindowLimiter, GlobalWindow, Pace, LimitScope, RateLimitState, rate_limit_headers | `@client/ratelimit` (ported: `@http.Headers` → `@model.Headers`, `@sync.Gate` → `@clock.Gate`) |
| Attempt (with body) / observer | `Attempt` without body; a 429 body is read from `error` = `UnexpectedStatus(.., body~)` (requires a raising reader) |
| Paginator / Page (::new, with_cursor) | `@client` (moved) |
| json | `@mttp/jsonkit` |
| `from_client(@runtime.Client)` in the SDK facades | `from_client(@client.Client)` |

### 8.5 gaato/requesto 0.2.2 (v0.2; shape per M-06)

| Today | mttp |
|---|---|
| Response.url / history / elapsed / retries | `Reply.attributes` set by FollowRedirects (final URL, history); elapsed and retries from the observer |
| Retry | `Client` retry (**changed order**: retry now sits above redirects, so a 503 on hop 2 re-sends hop 1) |
| Digest | kept inside requesto as a `from_fn` wrapper (moonbitlang/x stays requesto's dependency), or dropped with requesto |
| Cookies | `client/cookies.Cookies` wrapper |
| steps / on_request / on_response | Backend wrappers (**changed**: they run per attempt, not once per call) / observer |
| MockTransport | `BackendStub` / Router-as-Backend |
| sse (idle_timeout) / each_line | `as_sse` + `read_idle_ms` / `as_lines` |
| RequestoError | `TransportError` + `ResponseError`; the facade may re-wrap them but adds no logic |

### 8.6 Consumers

| Consumer | Change |
|---|---|
| **SDKs, phase 1** | §4.12 emitter changes. Facades take `(&Backend, &Clock, timer?)` and build a `Client`; `OpenAI::new`/`Anthropic::new(timeout_ms~, total_timeout_ms?)` map to `options.timeout_ms` and `total_ms`, and `GitHub::new(timeouts?)` to the `Timeouts` row of §8.4. openai and anthropic use `RetryPolicy::stainless`. github uses `GitHubRetry` (ported to TransportError/ResponseError/GraphQL error), `WindowLimiter`, and `Paginator[T, Error]` over `parse_link_next`. Public signatures become open-raising. github goes last. |
| **codex-protocol** | `@sdkjson` → `gaato/mttp/jsonkit` (qualified `Value`/`Null`/`Absent` constructors rewritten). |
| **jsonrpc-async, codex-app-server** | Untouched until Stage R. They expose moonbitlang/async types, so they switch in the Stage R train. |
| **discord 0.14** | See the table below. |
| **discord_voice 0.4** (new in the plan) | Stage 2: gaato/http/clock + http-async (AsyncClock, with_timeout_opt, 59 VirtualClock uses) → `@mttp/clock` + `@net/runtime`; re-release because it depends on discord. Stage R: its `&@io.Reader` (OggOpusSource) and `TaskGroup[X]` (VoiceConnection::start) switch with the runtime. |
| **gaato/discord-cli 0.1.8** (published; not in /home/user) | Depends on discord 0.13.0 and imports moonbitlang/async 0.22.5 itself. Moves with discord 0.14 at Stage 2, and again in the Stage R train. |
| **gaato/kbbi 0.1.6** (published; not in /home/user) | Depends on gaato/http 0.4.0, http-async 0.4.1 and moonbitlang/async 0.22.5. Either migrate it to mttp at v0.1, or leave it on the 0.4 stack, which then stays pre-R **[needs-user-input, Q16]**. |
| **gaato/req 0.1.0** | Already deprecated in the index (`yanked_reason`: "Renamed to gaato/requesto"); no action. |
| **mbt-sdk/conformance** (unpublished) | Its HTTP corpora move to `mttp/conformance` (Stage 0); the jsonrpc corpus stays. |
| **runtime-tests** | Client-loop tests move in-module (run_sync); transport tests move to net-tests; live tests stay unpublished. |
| **codecs.mbt** | Unchanged; consumed by mttp-net/codings only. |

discord 0.13 → 0.14:

| discord 0.13 | discord 0.14 |
|---|---|
| `http.Client(transport? : &@gaato/http.Transport)`; the sdk-runtime Client | `backend? : &@client.Backend`; `@client.Client` |
| `request_timeout_ms` (owned AsyncTransport's `timeout_ms`, or `Timeouts.attempt_ms` around a shared transport); `max_connections` (passed as `max_idle_per_origin`); `MAX_RESPONSE_BODY_BYTES` (AsyncTransport `max_body_bytes`) | `Client` `options.timeout_ms`; `AsyncBackend max_idle_per_origin`; `options.max_body_bytes` (and the owned AsyncBackend's `max_body_bytes` ceiling) |
| `DiscordHttpError::Transport(phase~ : @gaato/http.Phase, ..)`, `Timeout(phase~ : @gaato/http.Phase, ..)` | `phase~ : @model.Phase` (**public break**) |
| DiscordRetry over SdkError | `impl @client.RetryDecider` over Error (ported in `wf2/consumer-migration/cm/src/discord_rest`) |
| `REPLAY_SAFE_HEADER` + ClosedGate header stripping | the `@model.replay_safe` attribute; ClosedGate as a `from_fn` wrapper raising `Kind::Closed` |
| `bucket~` / `global_exempt~` | attributes |
| telemetry from `Attempt.body` | from `Attempt.error`'s `UnexpectedStatus` body (the 1 MiB cap now bounds it) |
| ratelimit (WindowLimiter, ...) | `@client/ratelimit` + `@runtime.SemaphoreGate` |
| `coordinator.RemoteRateLimiter` | `impl @client.RateLimiter` |
| Paginator::new | kept |
| `pub using @ahttp {type RequestMethod}`; `Route::custom(request_method~)` | `@model.Method`. `RequestMethod` is moonbitlang/async/http's type, not gaato/http's, so this removes one runtime type from discord's public API and one Stage R break. discord/http still imports moonbitlang/async (`with_task_group`, `is_being_cancelled`, `pause`) |
| sdk-runtime/json in model, interaction, http, framework, examples/live_probe, discord_voice tests | `@mttp/jsonkit` |
| `@clock.Clock` (gaato/http) | `@mttp/clock.Clock` |
| endpoint_http (stock parser; exposed to F36–F38 today) | Behind a header-limiting proxy, and the README says so, until it adopts `h1`: at Stage 3 if Q9 (c) is chosen (own-codec loop on raw Tcp, as `serve_conn_own_codec` in `wf2/runtime/v0225/src/net`), otherwise at Stage 4. At Stage 4: Endpoint with `security = map3(signature_header("x-signature-ed25519"), signature_header("x-signature-timestamp"), raw_body())`, `authenticate = verify.InteractionVerifier` (ed25519 stays in discord), served by `@server.serve` with discord's limits (1 MiB, 5 s, 5 s, 256) and **`handler_timeout_ms = None`**: the 2.5 s deadline stays in `handle_signed_http`, which answers 504 and lets deferred work continue. The `serve_interactions` handle (addr, close) is rebuilt from `on_listen` plus cancelling the task, with a port-0 test. |
| facade_interactions_js and the host adapters in `examples/` (Workers, Fastly, Vercel, Deno, Bun, Lambda URLs) | host-neutral `fetch_handler(handler)(req, background)`; the per-host JS shims keep today's shape (`handleInteraction(request, config, scheduleBackground)`); deferred work through the `background` attribute |
| re-exported `ServerConfigError` | mttp-net's type; qualified constructors such as `@discord.InvalidMaxBodyBytes` must be rewritten |
| gatewaysim and tests: `@simclock.VirtualClock(..)` (152 call sites in discord.mbt), `NoQuiescence` | `@net/runtime`, same constructor form, so only the import alias changes |
| gateway websocket | discord's own; switches in Stage R |

## 9. Decision log

| Id | Decision | Status | Rationale |
|---|---|---|---|
| M-01 | Modules: gaato/mttp (core only; incl. clock, clock/fake, jsonkit), gaato/mttp-net (all I/O), gaato/mttp-gen (tool, later). Existing gaato/http, http-async, sdk-runtime, requesto kept until Stage 6. | proposed | Module imports reach every consumer (F31); only external deps justify a module (R-12, S-02). |
| M-02 | clock and clock/fake are packages of gaato/mttp, with today's names and signatures. | proposed | No non-HTTP consumer; consumers compile only imported packages (F18). |
| M-03 | jsonkit is `gaato/mttp/jsonkit`; alternatively it stays in mbt-sdk. | decided (§0) | Location only; the alias must not be `json`. |
| M-04 | mttp-net: backend, codings, runtime (v0.1); facade (v0.2); server, fetch (v0.3); files later; `internal/io`. No digest. Name mttp-net vs mttp-async. | decided (§0) | Digest's crypto dependency would reach every consumer; only requesto uses it (S-09). `internal/` keeps the bridges unimportable, as discord does. |
| M-05 | Runtime transition: signatures stay runtime-free; the switch is a flag day per application graph (Stage R), editing consumers' manifests. | proposed | The runtimes cannot coexist (F35); async main/test needs the runtime in each consumer's manifest (F15, R-10). |
| M-06 | Exactly one facade at v0.2: requesto 0.3 (thin, no HTTP logic) or `mttp-net/quick` with requesto deprecated. | decided (§0) | Neither has a consumer in the workspace (S-10). |
| M-07 | Digest and ChallengeAuth leave the core; requesto implements Digest itself if kept. | proposed | S-09. |
| M-08 | Monorepo with moon.work, plus the resolver gate, manifest-vs-index ledger, per-target test counts and paired-runtime mbti diff. | proposed | Workspace overrides hide real resolutions (F30). |
| M-09 | mttp ↔ mttp-net compatibility rule: option 1 (each mttp minor compiles the previous mttp-net minor) or option 2 (mttp-net patch per mttp minor). | needs-user-input | Lockstep cannot be enforced (F29, R-07). |
| M-10 | Reserve `gaato/mttp/v2` as the escape hatch. | proposed | Only a new path coexists (F28). |
| M-11 | Publish gate: mttp 0.1 and mttp-net 0.1 are published only after discord REST and openai pass against them as moon.work path members. | proposed | Under F28 every API fix found while porting would otherwise be a breaking 0.2. |
| E-01 | `TransportError(kind~, phase~, detail~)` with `#non_exhaustive Kind`; Int limits. | proposed | Extensible without breaking matches (F3); one integer type at every seam (I-14). |
| E-02 | `ResponseError` + `InvalidRequest`; SdkError dissolves; SDK signatures become open-raising. | proposed | CM-12; sttp ResponseException. |
| E-03 | Declared errors: classify + per-variant codecs; same-status variants tried in order; no serve_result. | proposed | Verified (SC-04); serve_result had no consumer (S-13). |
| C-01 | `Backend { send(Request, RequestOptions) -> Response raise TransportError; close }`; no WebSocketBackend. | proposed | E4038 rules out polymorphic send (F1); WS deferred. |
| C-02 | Wrappers are Backend structs, or `from_fn`; no `layer`. | proposed | `layer` was one line over from_fn (S-04a). |
| C-03 | `ResponseAs{accept_head, reject, read, streaming}` with a public `ResponseAs::new`; `any_status`; buffered `from_head`; no `_always`/`as_either`. | proposed | Fixes call_with retries (I-03, verified); one mechanism (S-04b). |
| C-04 | Request shaping on `@model.Request`; opaque `ClientRequest[T]::new(raw, response_as)` with per-field option overrides and `ClientRequest::attribute`; no PartialRequest, RequestBuilder or WebSocketRequest. | proposed (overrides and `attribute` not in wf3/rev) | S-03, I-11, CM-02; endpoint calls must be markable as replay-safe or exempt. |
| C-05 | Placement rule: Backend wrapper / Client loop / Client defaults. | proposed | Unchanged principle. |
| C-06 | `client/retry` and `client/ratelimit` ported (substitution table in §4.4); `RetryDecider` over Error; `RetryContext::new` kept; presets keep today's method rules (`conservative`, `stainless`). | proposed (real port needs-prototype; wf3/rev has a stand-in) | I-12, CM-15; both packages name `@http.Headers`/`@sync.Gate`/`HttpError` today. |
| C-07 | Rate limiter kept; the bucket comes only from the `rate_limit_bucket` attribute, set by the facade or by `Endpoint::rate_limit_bucket(f)`, never from the operation id; release uses the head's status and headers once a head is known. | proposed | S-04d, S-12 (verified); GitHub and discord bucket by method, URL and route. |
| C-08 | One attempt deadline (`timeout_ms`), the `body_deadline` flag, `read_idle_ms`; Client `total_ms` shrinks it; no attempt starts after the total; non-positive limits fail at once; Timer only as fallback. | proposed (deadline rules not yet tested in wf3/rev; backend side needs-prototype) | RT-07, S-04c, CM-09; sdk-runtime's `check_deadline` and `retry_timeouts_test.mbt`; flag and fallback verified. |
| C-09 | Typed attributes on Request **and** Response, from v0.1. | proposed | replay_safe, operation_id (v0.1), remote_addr, background, route_template (v0.3); adding the field later would break literals (E4044). |
| C-10 | `Client` (backend + defaults + policy) is the only sending path; base URLs joined by prefix. | proposed | sdk-runtime's shape (S-03); RFC 3986 resolve drops /v1 (CM-01, verified). |
| C-11 | Client-wide `options : RequestOptions` on `Client::new` (v0.1); AsyncBackend keeps `max_body_bytes` as a hard ceiling. | proposed (not in wf3/rev) | discord, openai, anthropic and github all set client-wide timeouts or body caps. |
| C-12 | The loop enforces only replayability (a `Wait` on an unreplayable request becomes `Stop(NotReplayable)`); method gating is the decider's. `Body::Stream` keeps the take-once guard. | proposed (needs tests; take-once cell needs-prototype) | `stainless` resends POST today; CONTRACT 8. |
| C-13 | `decompress`: true sends the full Accept-Encoding when the request has none and decodes; a request's own Accept-Encoding passes through; false sends the request's value or `identity`. | proposed | Keeps http-async's behaviour; F40. |
| X-01 | `Request.url : String` (absolute or relative; parsed at send). | decided (§0) | Generated code stays non-raising; a read-only `Url` field forces E4036 or new raises (CM-02, S-11). |
| X-02 | Int status; `#non_exhaustive Method` with Show; immutable ordered Headers. | proposed | I-13, S-05. |
| X-03 | UriBuilder/UriPart/Trusted at v0.2; `uri()` returns String (no raise). | proposed | No v0.1 consumer (S-11). |
| X-04 | Pull-only bodies in both directions; one `Response` type; `#non_exhaustive Body`. | proposed | S-04e/f; verified. |
| X-05 | Server SSE as pull `EventStream` → `Body::Stream`; no push bridge. | proposed | Replaces the old needs-prototype item; verified through Router-as-Backend. |
| X-06 | WebSockets deferred beyond v0.4; later order: sans-IO `mttp/ws` codec with bounds (+ Autobahn), client over `@http.Client` passthrough, server via the h1 101 hand-off, `WsEndpoint` last. | decided (§0) | No consumer (S-08). The runtime client can send request headers on native/wasm; the real gaps are listed in §0. |
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
| P-11 | apispec/openapi at v0.4; merge rules; AND security; signatures as header parameters; OpenAPI 3.1 only. | proposed (3.1-only needs-user-input) | I-15, SC-04, SC-05; verified. |
| P-12 | Codegen: tools/gen (Python) phase 1 now; mttp-gen dropped until a consumer exists. | proposed | S-07, R-11. |
| P-13 | Header outputs (`and_header`, `fixed_header`); `and_status`, `set_cookie` at v0.3; WWW-Authenticate on declared 401s. | proposed | SC-03, CM-13; header output verified. |
| T-01 | `run_sync` in one file; its package allows `unused_async`. | proposed | S-14; verified. |
| T-02 | Conformance: corpora, ledgers, the cross-layer e2e gate, per-target test counts. | proposed | I-16, RT-15, R-08. |
| T-03 | FakeClock in mttp/clock/fake; VirtualClock in mttp-net/runtime. | proposed | — |
| T-04 | `testing` (model + client only) separate from `endpoint/testkit`. | proposed | S-06. |
| T-05 | `moon check --deny-warn` on all 4 targets with both toolchains is a Stage 0 exit criterion and a CI gate. | proposed | wf3/rev has 84 warnings today (F53). |
| B-01 | Bounds as in §5.2. | proposed | — |
| B-02 | A sans-IO HTTP/1.1 codec (`gaato/mttp/h1`) replaces the stock server parsers: version, 100-continue, chunked decoder reporting end, trailers and consumed bytes; later also used by AsyncBackend for responses. | needs-prototype | RT-04, RT-06, RT-13; RESOURCE_BOUNDS client-side known gap. |
| B-03 | Server body limit = `min(adapter ceiling, endpoint override or router default)`; both adapter ceilings 1 MiB; an override above a known ceiling is an advisory definition problem. | proposed | Four knobs without a stated precedence. |
| A-01 | Runtime-free adapter API: serve (+ Bind/Accept, ServeError); host-neutral `fetch_handler(handler)(req, background)` with JS shims per host; `pub fn fetch`. | proposed (fetch background needs-prototype) | RT-01, RT-08, RT-09, RT-12, CM-05; discord supports six JS hosts, and Fastly needs `waitUntil` synchronously. |
| A-02 | Bounded content decoding; Accept-Encoding per C-13. | proposed | RT-16. |
| A-03 | mttp-net/server never ships without `h1`. Until discord's endpoint_http adopts `h1`, it sits behind a header-limiting proxy, and discord's README says so. | proposed | RT-05; F36–F38 apply to endpoint_http today. |
| G-01 | SDK phases: phase 1 mechanical retarget (§4.12); phase 2 opt-in after v0.3/v0.4. | proposed | CM-02, CM-04. |
| G-02 | No forward shim. Default (d): clocks are new traits and mixed graphs pass two clocks. Optional gaato/http 0.5.1 `bridge` package for mixed graphs. Alternative (a): `mttp/clock` re-exports gaato/http 0.5.0's traits until a later minor. | decided (§0) | A forward 0.5.1 shim is inert unless something requires it (F33). |
| G-03 | discord 0.14 as in §8.6 (including the DiscordHttpError phase type and the client options); interactions server onto `h1` at Stage 3 (Q9 (c)) or Stage 4. | proposed (stage of `h1` needs-user-input) | CM-05, CM-06, CM-10. |
| G-04 | Retirement by advisory deprecation; no yanks; security via patches plus raised minimums. | proposed | F26, F27. |
| G-05 | Stage R train list (§8.1), including discord-cli and kbbi if migrated. | proposed | RT-03, CM-10; registry index. |
| G-06 | Old-stack graphs at Stage R: (a) an http-async 0.5.x patch on core async, or (b) frozen pre-R. | needs-user-input | F35; http-async's API names no runtime type; F26. |
| G-07 | Published consumers kbbi and discord-cli join the plan; kbbi migrates or stays on the 0.4 stack. | needs-user-input (kbbi) | Registry index: kbbi 0.1.6 and discord-cli 0.1.8. |
| G-08 | discord breaks twice (0.14 at Stage 2, again at Stage R) rather than once. | needs-user-input | The REST move need not wait on a toolchain. |
| N-01 | Naming rules (§5.9). | proposed | — |
| N-02 | Adapters set `remote_addr` and `background`; the Workers shim also sets `env`; handlers read them through `attribute`. | proposed | SC-07, RT-08. |
| N-03 | HTTP/1.1 only; TLS and HTTP/2 via a front proxy. | needs-user-input | — |
| V-01 | Staged tiers v0.1 → v0.4 (§7). | decided (§0) | S-01, S-07. |

## 10. Verified facts and refuted assumptions

"4×2" means wasm-gc, js, native and wasm, each with moonc 0.10.16+b1a0e846e and 0.10.17+d971670cd. Paths are relative to the scratchpad directory given at the top.

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
| 1 | `run_sync` depends on undocumented intrinsics (`%async.run`, `%async.capture_cancellation`, nocancel). | One file; daily canary; fallback to native-only suites in net-tests. |
| 2 | Stage R is a flag day across ≥ 8 modules, and core async's API is still being renamed. A library left on 0.22.x fails at link time with a confusing `pool` error. | Canary in a core-main checkout; paired-runtime mbti diff; report the non-static `pool` upstream; document the link error. |
| 3 | Server exposure before `h1` lands. mttp-net/server never ships without `h1`, but **discord's current endpoint_http has the unbounded-head and CL+TE exposure today** (F36–F38). | A-03 (behind a proxy, stated in discord's README); `h1` with adversarial probes; Q9 (c) fixes endpoint_http at v0.2 instead of v0.3. |
| 4 | Under MVS, breaking 0.x releases propagate and patches do not. | Resolver gate, coordinated minimum bumps, `/v2` reserved. |
| 5 | Workspace builds hide consumer resolutions. | Resolver gate outside moon.work; manifest-vs-index ledger. |
| 6 | Closure-erased endpoints: hand-built `Input::new` atoms can disagree with their closures. | `verify`, round-trip properties. |
| 7 | A classify that misses a case turns a declared error into a 500. | A test helper that raises every declared case; mttp-gen later. |
| 8 | Schema-as-Json can drift from derive. | objectN/tagged codecs; conformance validates encoded samples against the schema. |
| 9 | Readers inside retried attempts must be pure; a side-effecting buffered reader runs again. | Documented; streaming readers run once. |
| 10 | JS limits: fetch follows redirects, merges headers, hides Set-Cookie and decodes codings; request bodies are buffered; each serverless host keeps deferred work alive differently (Fastly only synchronously). | Per-target CONTRACT exceptions; host-neutral `fetch_handler` with per-host shims; background prototype on Workers, Fastly and Lambda. |
| 11 | wasm (moonrun) async is experimental; wasm-gc has no runtime and silently skips async tests. | Per-target test counts; run_sync for wasm-gc coverage. |
| 12 | The credentials-first ordering may surprise tapir users. | Documented; overridable via decode_failure (P-04). |
| 13 | Unmeasured costs: immutable Headers copies, closures per request, the attributes slot trick (which assumes no preemption between write and read). | Benchmarks before v0.3. |
| 14 | `@json.parse` recursion depth is unbounded or unverified. | Depth probe; bounded parser if needed. |
| 15 | Migration size: discord's public API, three generated SDKs (github ≈ 243k lines), discord_voice, requesto users. | Mechanical emitter changes; staged tiers. |
| 16 | String URLs surface invalid targets only at send time (`Kind::Invalid`, unsent). | Accepted for v0.1 (X-01); `uri()` at v0.2. |
| 17 | The ECMA pattern translator covers only a subset; untranslatable spec patterns are refused. | Corpus from the three SDK specs; refusal at construction, not at runtime. |
| 18 | The v0.3 endpoint layer is experimental, and discord would ride its churn. | Mark experimental; one consumer only until it settles. |
| 19 | If the reverse shim (G-02 (a)) is chosen, deprecating gaato/http warns every mttp user. | Defer deprecation until mttp drops the re-export. |
| 20 | A hostile server or proxy gets unbounded, quadratic ingest against every AsyncBackend client: response heads, chunk-size lines and trailers have no byte limit (F63). | Until AsyncBackend parses responses with `h1` (`parse_response_head`, ChunkedDecoder) or upstream adds limits: `timeout_ms` bounds it; a client case in the adversarial suite. |
| 21 | Stage R strands old-stack graphs: anything still holding http-async 0.4/0.5 (requesto 0.2, kbbi, discord ≤ 0.13, discord_voice ≤ 0.3) cannot link beside a post-R mttp-net (F35). | G-06: an http-async patch on core async, or a documented freeze (Q15). |
| 22 | discord breaks its public API twice: at Stage 2 (Backend, `DiscordHttpError` phase type, Client parameters) and at Stage R (`TaskGroup[X]`, `&@io.Reader` in discord_voice). | Q14; mapping `RequestMethod` to `@model.Method` at 0.14 removes one Stage R break. |
| 23 | The v0.1 client rests on rules not yet prototyped or tested: the real `client/retry` port, Client-wide options, deadline rules, the take-once cell. | Stage 0 exit criteria (§4.4 test list); publish gate M-11. |

## 12. Open questions for the user

Q1–Q4, Q6–Q8, Q11 and Q12 are answered in §0. Q5, Q9, Q10 and Q13–Q16 concern releases and the migration of consumers and stay open.

1. **Scope tiers.** Ship v0.1 as the client half only, with the endpoint layer as an experimental v0.3 and OpenAPI at v0.4 (proposed)? Or keep the endpoint layer in the first train?
2. **Request.url.** A `String` target parsed at send time (proposed, keeps generated SDK code non-raising)? Or the parsed `Url` with a non-raising `Url::from_encoded` for generators?
3. **requesto.** Keep it as a thin v0.2 facade, or deprecate it in favour of `mttp-net/quick`? Either way there is exactly one facade.
4. **Compatibility shim (G-02).** None, with an optional gaato/http 0.5.1 bridge for mixed graphs (proposed)? Or a reverse re-export of gaato/http's clock traits from `mttp/clock` until a later minor?
5. **mttp ↔ mttp-net rule.** Option 1 (mttp keeps compiling the previous mttp-net minor; proposed), or option 2 (mttp-net patch per mttp minor)?
6. **Names.** `gaato/mttp-net` or `gaato/mttp-async`? Should jsonkit live in the mttp repo (proposed) or in mbt-sdk?
7. **Invalid bodies.** 400 for everything (tapir default; proposed) or 422 for a well-formed body that fails validation?
8. **Credentials first.** Accept the documented deviation from tapir (401 before any 400)?
9. **discord interactions.** (a) Leave endpoint_http as it is, behind a proxy, until v0.3 (the previous default); (b) move it onto the endpoint layer earlier, behind a proxy; or (c) ship `h1` in mttp 0.2, independent of the endpoint layer, and have endpoint_http read heads and chunked bodies through it on raw Tcp (an own-codec loop, as `serve_conn_own_codec` in `wf2/runtime/v0225`). Proposed: (c). It fixes F36–F38 for discord users before v0.3 and is backed by the 0.22.5 re-run in F36; it costs moving `h1` (still [needs-prototype]) one tier earlier.
10. **SDK phase 2.** Should openai, anthropic and github emit Endpoint values after phase 1 (needs v0.3 header outputs and v0.4 docs)? Proposed: decide after v0.4; no SDK emits endpoints before then.
11. **Protocols.** HTTP/1.1 only (TLS and HTTP/2 via a front proxy), OpenAPI 3.1 only, and no AsyncAPI (proposed)? Or widen any of them?
12. **WebSockets.** Defer until after Stage R, and add them only if discord's gateway moves onto mttp (proposed)?
13. **Retirement.** Deprecate gaato/http, http-async and sdk-runtime once the last gaato consumer has moved, with no yanks (proposed)?
14. **discord breaking releases.** Break discord twice, with 0.14 at Stage 2 for mttp and again at Stage R for core async (proposed, because the REST move does not wait on a toolchain)? Or hold the REST move and break once at Stage R?
15. **Old stack after Stage R.** Release an http-async 0.5.x patch on core async, so that requesto 0.2, kbbi and discord ≤ 0.13 keep linking beside new code (proposed)? Or freeze old-stack graphs before Stage R?
16. **kbbi and discord-cli.** Migrate both in the Stage 2 and Stage R trains (proposed)? Or leave kbbi on gaato/http 0.4?

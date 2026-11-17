# Test coverage ledger

Line coverage of the modules in `scripts/modules.tsv`, measured on native
with `moon test --enable-coverage` and reported in Coveralls-JSON mode. The
rule is a closed ledger:

> **Every uncovered line is either covered by a test or listed below with a
> reason.** `scripts/coverage_report.mbtx` enforces this: a file with uncovered
> lines must have a row here whose budget is at least the actual count, and
> the script fails otherwise. Rows for fully covered files are flagged as
> stale and rows with slack are noted, so budgets only ever shrink.

## Running it

```sh
moon run scripts/coverage_report.mbtx                    # measure, print tables, check the ledger
moon run scripts/coverage_report.mbtx -- --from-json _build/coverage_report.json   # recheck only
```

The full gates run it locally and in CI, so a change that leaves a line
unexplained or over budget fails in both environments.
Exit status: 0 = ledger OK, 1 = an unexplained or over-budget file, 2 = the
run itself failed (a failing test, a build error).

`--from-json` only rechecks a stored report against the ledger; it does not
rerun the tests.

HTTP/1 numeric arithmetic is also verified by `moon prove` in the
dependency-free `mttp_core/src/internal/number`: the recursive positional
model, bounded digit step and fixed-array fold, including exact overflow
refusal. [The proof record](mttp_core/src/h1/PROOFS.md) describes the boundary
between that proof and h1's tested UTF-16/ASCII mapping, OWS and exceptions.
The numeric tests cover empty/invalid inputs, leading zeros, the signed
63-bit bound and one past it in both bases. No uncovered-line exemption is
added: a targeted native run covered all 12 lines of h1's `numbers.mbt`
and all 21 lines of `internal/number/number.mbt`. The manual
`scripts/gates.sh prove` gate checks fresh reports and
four false contracts with either pinned solver, outside quick/static/full.

### What is measured

- Sources: every non-test `.mbt` under `<module>/src/` of every library or
  conformance module. Example and benchmark executables are excluded: their
  output and timings are not library behavior covered by this ledger.
- Test drivers: every package of those modules.
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

The h1server read-ahead and timeout regressions run over sim + Driver on all
four targets (74 tests per target). Its native coverage is 315/318 lines;
the three remaining lines are the existing request-body defensive guards and
future response-Body arm listed below. The ownership handoff, bounded buffer,
peer failure/EOF distinction and input/producer timeout split add no exemptions.

### Pitfalls the script pins

- In a `moon.work` workspace `moon -C <member> test` tests every member. The
  script runs `moon test --target native --enable-coverage <package dirs>`
  from the workspace root instead.
- Counters from earlier runs and trace maps of moved or deleted packages
  silently corrupt the merge, so every run deletes `_build/**/moonbit_coverage_*`
  and `_build/native/debug/test` first, and passes the measured modules' trace
  maps and counter files explicitly.
- `-f summary` omits fully covered files, which skews totals; the script uses
  the Coveralls JSON.
- moon's bundled tcc cannot link on some hosts (openSUSE); the script sets
  `MOON_CC=cc` unless it is already set.

## Policy

The OpenAPI comparator's initial native measurement left the following small
structural cases outside the handwritten change-kind tests. Later tests cover
the JSON payloads and the requiredness relaxation branches; the remaining
budgets are conservative until the coordinator's next combined measurement.

| File | Budget | Reason |
|---|---:|---|
| mttp_core/src/apispec/diff/compare.mbt | 16 | Remaining malformed string fallback, root/non-object JSON Pointer targets, metadata-reference cycles and budget stops, and response-header-only alternatives. Review regression tests cover array pointers, unresolved path-item refs, additional operations, ref/inline transitions, conservative contexts and both sides' source provenance (including nested arrays, removals and budget overflow). Budget retained pending the coordinator's combined native measurement. |
| mttp_core/src/client/httpcache/body.mbt | 2 | Future non-exhaustive Body constructor cannot be constructed by current callers. The collecting stream's defensive read-after-close guard sits behind StreamBody's TakenStream, which returns sticky EOF before calling the source again; the public EOF/close contract is tested. |
| mttp_core/src/apispec/diff/compare.mbt | 16 | Remaining malformed string fallback, root/non-object JSON Pointer targets, metadata-reference cycles and budget stops, and response-header-only alternatives. Review regression tests now cover array pointers (including invalid indices), unresolved path-item refs, additional operations, ref/inline transitions and conservative reference contexts. Budget retained pending the coordinator's combined native measurement. |
| mttp_core/src/apispec/diff/operations.mbt | 6 | Parameter-copy budget-stop guards are not individually driven. Requiredness relaxation, body additions, parameter serialization/defaults, literal path capture matching and scope-set matching have regression tests; budget retained pending the combined measurement. |
| mttp_core/src/apispec/diff/schema.mbt | 6 | Absent or malformed type values, malformed nonnumeric bounds, primitive boolean schemas, and stopping between schema keywords. Structured variance, negated nested/reference traversal, overlapping constraints and disjoint-but-interacting reference sibling conjunctions have regression tests. |

The listener adapter is exercised over real loopback sockets on native and
wasm, including shutdown, streaming responses, admission, deadlines and
background cleanup. Its immutable internal lifecycle has the same snapshot
tests on both targets. The JS-only fetch adapter and host shims run under
Node, outside this native line-coverage measurement; their 31 tests include
the 1 MiB/4 MiB boundaries, cancellation, caught input failures during response
prefetch across every host shim, shutdown of close-on-shutdown streams through
the process host shims, the Workers shim's one lazy import, `env_string` on odd
environments, and the compiled export smoke test. Node allows what Workers
refuses, so `scripts/gates.sh workerd` (part of `full`) also runs the Workers
example on workerd and checks its replies and logs. The listener's matching post-prefetch behavior also has a real socket regression.

The JS-only `fetch` WebSocket adapter runs queue byte/count overflow, sticky
error mapping, cancellation, concurrent recv and bounded send/close tests under
Node. The interop runner checks Node/Deno/Bun clients against native, then
Deno/Bun fetch servers. The workerd gate checks the Workers echo route on the
real runtime. These JS-only sources are absent from native coverage.
`fetch/websocket_wbtest.mbt` also pins cancellation and asynchronous cleanup
joining for handlers blocked outside recv, application cookies alongside Deno
handshake fields, and repeated Bun list headers. Pinned interop checks these
against real Deno/Bun upgrades and the native handshake server.
The workerd gate repeats three concurrent WebSocket sessions followed by a
Workers client request for 20 rounds in one isolate, covering completion
callbacks that would otherwise be registered in another request's context
when the shared scheduler resumes a session. Node does not enforce that
request lifetime boundary; the "WebSocket operations and wait callbacks stay
in the socket scope across scheduler callers" test uses AsyncLocalStorage to
check operation, completion and cancellation callback ownership directly.
Under CPU contention, early replies with unread uploads also reset connections
in a pure JavaScript Worker, independently of MoonBit; see upstream
[workerd #7634](https://github.com/cloudflare/workerd/issues/7634). Consuming the
upload to EOF before replying avoids that host failure but would violate the
adapter's tested contract to leave unused input to the host.
The startup regression holds Deno/Bun/Workers sockets in CONNECTING, also
delivers Bun's socket only after abandonment, and checks Close, idle completion
and that the handler never starts. Workers' real accept is synchronous; the
delayed fake tests the common startup lifetime while workerd covers real accept.

The consumer lifecycle regressions in `mttp_core/src/client/close_test.mbt` cover
observer closure and closure during backoff, the last reply/error/selected
stream, paired Admission release, idempotent close and sends after close.
They use a local sequential fake clock; the portable Driver only runs the
coroutines and schedules the other closing task, without virtual-time sleeps.
`mttp/src/backend/socket_test.mbt` checks idle expiry at 49/50 ms and
the Head phase timeout at 74/75 ms with injected VirtualClock, with both the
default and an explicit ClockTimer on an independent clock. `fetch.js_test.mbt`
checks injected head and body idle deadlines at 59/60 ms and abort cleanup on JS.

Must be covered by tests:

- pure logic: header, URL and body assembly, the parsers, retry and
  rate-limit arithmetic, the client loop, the connection engines;
- every `raise` arm reachable through the public API.

Accepted as uncovered (needs a row):

- defensive arms that are unreachable by construction;
- platform-only fallbacks that native never takes;
- testable lines not yet tested, marked `not yet tested`: these are the
  queue for new tests, not a permanent exemption.

Budgets are exact uncovered counts at the last measurement.

The OpenAPI status audit dispatches all final codes (200–599) through 192
configurations: all combinations of fixed/dynamic success and declared-error
outputs, authentication on/off, absent/raw/typed bodies, and both declaration
orders. It compares the selected explicit/default response's media, inclusive
schema alternatives and header requiredness with actual handler, authentication
rejection and default framework responses. Separate regressions cover 204/304
body suppression and stream closure, dynamic empty/wildcard representations,
specific-media precedence, ordinary Auth input failures and invalid statuses.
These additions require no new uncovered-line exemptions.

The content annotation tests exercise codec-encoded defaults and examples,
builder and doc list ownership, duplicate names and undeclared statuses,
dynamic-status boundaries (200/599 accepted, 199/600 refused), and merged
response media examples. OpenAPI 3.1 and 3.2 golden outputs include webhook
content, shared schemas, tag descriptions and root security; JSON round trips
and reference checks cover these documents and treat example `$ref` values as
data. Cross-document checks cover duplicate webhook names and operation IDs,
conflicting named schemas and unresolved webhook schema references.

The Digest port (`mttp_digest/src/backend.mbt`, `digest.mbt`) and the private
conformance harness (`conformance/src/harness/*.mbt`) are fully covered on
native: 234/234 and 62/62 instrumented lines. Digest's black-box suites cover
the Backend checker, request stream cleanup, unchanged SendOptions,
cancellation, and POST → 401 → dial failure under an unsent-only retry rule.
The nonce-count regression suites exercise three concurrent same-nonce
challenges with both empty and populated caches, strictly increasing challenge
and subsequent preemptive counts, and new/stale nonce resets. White-box
boundary tests cover allocation of `ffffffff`, refusal to reuse an exhausted
count, retained challenge updates, FIFO eviction, and caller ownership of an
unanswered 401 at exhaustion.
The conformance suites exercise the harness through URL, cookie and SSE
corpora, including seeded SSE mutations and every short-input split. No
uncovered-line budget is needed for these additions.

## HTTP/1 mutation adequacy (2026-11-16)

`moon_mutest` 0.1.7 and `moonseal` 0.1.6 could not be installed on this
toolchain because their CLI dependency graphs support JS only, so
`scripts/mutate.mbtx` runs a bounded, hand-selected sample in a disposable
copy. The 50 sites cover comparison and limit boundaries, boolean operators,
negated guards, deleted raises/returns, ParseKind changes and swapped arms in
`head.mbt` (including HeadDecoder), `framing.mbt`, `chunked.mbt` and
`write.mbt`; h1, h1client and h1server tests run for each site.

Before closing gaps, 48 were killed, with two survivors and no timeout. H13 is
equivalent: the request-line three-part check removes every SP from the target
before its character guard. C03 exposed a gap at the maximum Int64 chunk size;
the exact `7fffffffffffffff` boundary test now kills it. Final result: 49
killed, zero survived, one equivalent, zero timeout. Run with
`scripts/gates.sh mutate`.

## Coverage-guided fuzzing (2026-11-16)

`fuzz/` holds two libFuzzer targets over mttp_core's parsers, compiled
from the C that moonc generates: `fuzz_h1` reads arbitrary bytes as a
request or a response (to GET, HEAD, POST, CONNECT or OPTIONS; default or
small limits) through the reader that `h1/reader_test.mbt` builds on the
codec, and `fuzz_ws` feeds them to `ws/frame` `Parser` as either role. The
first input byte picks the mode and the next two a cut. Each input runs
whole, cut in two there and (up to 2 KiB) one byte at a time; the targets
abort, and libFuzzer keeps the input, when an outcome is neither a value nor
a `ParseKind`/`FrameErrorKind`, when the cuts disagree, when `next` stops
making progress, or when a message the reader accepts does not read back the
same after the writer writes it (as `h1/property_test.mbt` checks).

`scripts/gates.sh fuzz [SECONDS]` (default 60 per target; daily in canary
at 300) builds them with ASan in a disposable copy. It works around two
toolchain facts on 0.10.20: moonc writes machine code for native unless a
package sets `cc-flags`, so the copy sets them to get C; and the C is
linked against the runtime's sources built with the system allocator, so
ASan sees every MoonBit allocation and libFuzzer supplies `main`. Seeds are
the byte literals of the h1 and ws/frame tests and the conformance vectors,
under each mode. A failure prints the abort message and the input (escaped
and in base64) and leaves the input in `_build/fuzz/`: the first three bytes
are the mode and the cut, the rest is the wire for a corpus row.

First runs (MoonBit 0.10.20, clang 23, a shared host under load; the same
gate also passed on Ubuntu 24.04's stock clang 18): 20 minutes each, about
1,500 exec/s for h1 (1.57M inputs, 2,197 → 2,634 edges) and 1,000 exec/s
for ws (1.21M inputs, 319 → 329 edges; the frame parser is small and the
seeds already reach nearly all of it). Neither found a crash, an ASan
report, a hang or a cut-dependent outcome in the codec. Both findings were
in the rewrite property that `h1/property_test.mbt` shares, which its
generators never reach:

- The seeds' own `status above 599` row: readers keep 600–999 and writers
  refuse them (h1 README), so the property now skips them.
- A POST without framing and exactly 100 fields: the writer adds
  `content-length: 0`, field 101, which default limits refuse on reading
  back. The writer may also add a byte per field (`a:b` → `a: b`), so the
  property now reads back with room above the limits.

Each has a regression test in `h1/property_test.mbt`. After both fixes a
further 10 minutes each (1.30M h1 inputs at 2,200 exec/s, 0.70M ws at
1,200) found nothing.

## Accepted uncovered

| File | Budget | Reason |
| --- | --- | --- |
| mttp/src/conn/dialer.mbt | 3 | Forward-compatible Trust arm: Trust belongs to the cross-target trust package, so the dialer must refuse future constructors that cannot be constructed in this release. The `SocketPort` impl the toolchain does not use: `Tcp::connect_to_host` takes an `Int` port on MoonBit 0.10.20 and a `UInt16` later, so one impl per toolchain is never called. Not yet tested: `Tcp::connect(addr)` after the refuse_internal guard accepts a public address. Loopback integration deliberately refuses those local destinations, and an external public-IP dependency would make the suite nondeterministic. The classifier's allowed and denied boundaries and the HTTP-to-real-resolver refusal path are tested; a controlled public-address network fixture remains future work. |
| mttp/src/conn/conn_io_next.mbt | 1 | Present only when the canary copies it from compat/core_async_next. `flush_partial_data` is not called: mttp never flushes a TLS session, and ConnIo holds no bytes to flush. |
| mttp/src/conn/conn_io.mbt | 1 | BinaryWriterImpl::get_controller is not called by core's current writer defaults; the controller is a stateless marker reserved for future buffering/locking. Each bridge still constructs and owns its controller as required by the core trait. |
| mttp/src/codings/body_source.mbt | 1 | Forward-compatible Body arm: a future body representation is refused instead of silently treated as empty. |
| mttp/src/codings/compress_requests.mbt | 1 | Defensive fallback for dictionary or future codings in the 415 hint check; the constructor rejects Dcb/Dcz before a wrapper can send them. |
| mttp/src/codings/decompress.mbt | 1 | Defensive fallback for a non-TransportError from read_decoded: this wrapper supplies a TransportError-only reader and ContentDecoder translates codec errors to TransportError. Cancellation is a scheduler signal. |
| mttp/src/codings/encoded_body.mbt | 1 | Defensive fallback for a non-TransportError from read_encoded: this wrapper supplies a TransportError-only reader and ContentEncoder translates codec errors to TransportError. |
| mttp/src/internal/socketconn/socket.mbt | 2 | The `IncompleteClose` arm of `read_failure`: MoonBit 0.10.20's TLS client returns EOF for a peer that closed without close_notify, so `incomplete_close` is false there; compat/core_async_next tests the arm on the toolchains that raise it, and the in-tree test covers the stickiness after it. Close before owner startup, pending read/write close, partial writes and caller cancellation races are tested. |
| mttp/src/internal/testtls/engine.native.mbt | 2 | The `WantWrite` and `Eof` outcomes of a handshake step: OpenSSL writes a handshake into a memory BIO whole and the engine's 64 KiB output buffer holds it, and no test client sends close_notify mid-handshake. Their handling is the same state machine wasm drives. |
| mttp/src/internal/testtls/testtls.mbt | 13 | Test-support code. Native OpenSSL takes all ciphertext on each call, so the input buffer never compacts or fills (wasm's host may take part); the handshake never needs a second output batch or sees close_notify; a session freed during a handshake or a write, a failing `SSL_write` or `SSL_shutdown`, and a write that moves nothing are defensive. Not yet tested: a read whose first call took a partial record (loopback delivers whole records). |
| mttp/src/runtime/coordination.mbt | 5 | Defensive task-group TransportError rethrow and non-TransportError mappings in supervision and protection: primary/monitor/protected work raise only TransportError, and primary/monitor errors are captured before the group joins. Cancellation is a signal and propagates independently. |
| mttp/src/server/response.mbt | 1 | Defensive read-after-close guard of the private response lease: the engine's acquired StreamBody reader already returns EOF without delegating after closure. |
| mttp/src/ws/upgrade.mbt | 6 | Defensive Offer.accept failure and unused server entropy; the JS handover and compression-option ignore lines are absent from native execution and checked through fetch_handler on JS, host.js_test.mbt, real workerd and the Deno/Bun interop servers. |
| mttp/src/server/serve.mbt | 9 | Defensive shutdown handoff and failure arms: stop after capacity wakeup or during accept/register/spawn handoff, accept failure after stop, configuration refused after the same immutable limits were validated before bind, independently cancelled acceptor while Running, worker errors suppressed during cancellation cleanup, and unexpected server-task errors. Stop normally cancels and joins the acceptor as a signal; real accept failure, full-cap shutdown, late accepted socket actions and jobs started during expiry cleanup have dedicated tests. |
| mttp/src/files/files.mbt | 8 | Defensive arms. The read-after-close guard of the private file body: the StreamBody reader every caller gets already ends after close without delegating. I/O failure arms on an already opened regular file: `fstat` for size and modification time failing (a 500), the file no longer being regular between the kind check and the open, and a positioned read failing mid-body (closed, then a `Network` error in phase Body). A test cannot make the kernel fail those on a file it just opened, nor swap the path between two calls deterministically; refusals before the open and a file that shrinks mid-body are tested. |
| mttp/src/runtime/timer.mbt | 1 | Defensive ordinary-error fallback of the generic timeout helper. Clock::sleep and Timer's callback are noraise, so current children cannot raise an Error; cancellation propagates independently. |
| mttp_core/src/driver/driver.mbt | 1 | Defensive arm: a task suspended by something other than its Driver. No async runtime is linked, so nothing else can suspend it. |
| mttp_core/src/ws/receive.mbt | 5 | Defensive Parser ordering guards (Payload and End always follow Head), refusal of an empty Conn read (the port requires nonempty chunks), and the supervision error arm: both reader and monitor catch their own errors, so a conforming Coordination has no TransportError to deliver. |
| mttp_core/src/ws/session.mbt | 8 | Defensive encoder and mask errors: outgoing opcodes/FIN are constructed internally, control sizes are validated, and masking has an exactly four-byte key. The protected supervision error arm is defensive because its children catch WsError and Clock.sleep is noraise. A scheduler-boundary guard tolerates Close between dispatch and the Pong worker by skipping a no-longer-pending/allowed Pong. Deterministic native schedules do not reach that guard; blocked pipes, partial control frames, cancellation, EOF/errors and exact/read-ahead-plus-one bounds have public regression tests. |
| mttp_core/src/h1client/client.mbt | 1 | Forward-compatibility arm of the `#non_exhaustive` `BodyTiming` match: every timing the module defines has its own arm. |
| mttp_core/src/h1client/phase_log.mbt | 1 | Forward-compatibility arm of the `#non_exhaustive` `PhaseEvent` match: the engine reports only the events the module defines, each of which has its own rank. |
| mttp/src/ws/connect.mbt | 23 | JS-only host and ready-session backend paths, including ignoring the compression option, are absent from native execution. host.js_test.mbt checks early extension refusal and compression-option handling; typed_test.mbt runs the connector over Router and pins 101 and 401 on JS. interop/ws_client runs the host path under Node, Deno and Bun; real workerd checks Workers fetch-upgrade with custom headers. |
| mttp_core/src/ws/handler.mbt | 1 | Server-role sessions never request mask entropy, so the injected failure-only entropy callback is unreachable. Typed endpoints exercise this hand-over through Router and real sockets; JS adapters consume the portable handler directly. |
| mttp/src/ws/compression.mbt | 2 | Defensive overflow check after a codec exception: the raw decoder normally returns NeedMoreOutput when the one-byte overflow probe fills before reporting a later malformed symbol; normal-return overflow is tested at exact capacity and plus one, including Close 1009. NeedMoreInput consumes every byte by the decoder contract, so its unconsumed-input guard is defensive. |
| mttp_core/src/h1client/failure.mbt | 3 | Defensive arm: an error that is neither a `TransportError` nor a codec `ParseError`. The ports raise only `TransportError`, and every codec call inside a phase raises `ParseError`; cancellation is not an `Error`. |
| mttp_core/src/h1client/proxy.mbt | 1 | Defensive arm: the CONNECT head refused by the wire writer. Its fields are the origin's authority, the proxy's credentials and the User-Agent of a request whose own head was already written. |
| mttp_core/src/h1client/response_body.mbt | 1 | Defensive arm: a `NoBody` framing in the body reader. A response without a body is returned with `Body::Empty` and never gets a reader. |
| mttp_core/src/h1client/timeouts.mbt | 1 | Overflow guard of the time left: it needs the clock to move back by more than 2^63 ms after the deadline was set. |
| mttp_core/src/h1client/upload.mbt | 1 | Defensive arm: a concurrent exchange that returns without a final head. Its primary returns normally only after one arrived; every other ending raises or is cancellation. |
| mttp_core/src/h1server/request_body.mbt | 2 | Defensive guards: retrying an already failed private body cursor (the public acquired reader closes after failure, and the session refuses reuse before draining a failed cursor), and draining while still owing 100 Continue (the response is already marked Connection: close, which skips drain). |
| mttp_core/src/h1server/response.mbt | 1 | Forward-compatible Body arm: a future response body representation cannot be constructed in this release and is refused as Invalid before writing a head. |
| mttp_core/src/sim/contracts.mbt | 2 | Defensive arms: `check_coordination_contract` requiring the outer supervision to raise its monitor's failure after a nested one was cancelled (the earlier monitor-failure step already requires it, and cancellation cannot be caught, so a nested supervision cannot turn into a normal return that would hide it); and the read of the stream `check_backend_contract` attaches with a negative declared length, which `StreamBody::take` refuses, so no backend can read it. |
| mttp_core/src/multipart/multipart.mbt | 1 | Forward-compatible Body arm: a future body representation cannot be constructed in this release and is refused as an unsupported part. |
| mttp_core/src/multipart/stream_body.mbt | 1 | Defensive closed-stream guard: the `StreamBody` wrapping the multipart stream returns EOF once closed, before delegating again, so this branch cannot be reached through the public body API. |
| mttp_core/src/multipart/reader.mbt | 1 | A Head event while reading a part body is excluded by scanner transitions and sequential reader ownership: the scanner emits End before the next Head, and End deactivates the part stream. Sticky-failure guards have a direct Scanner white-box test in reader_wbtest.mbt. |
| mttp_core/src/endpoint/multipart.mbt | 8 | Custom MultipartCodec::new extension fallbacks for schemas without properties and custom empty-path or Missing failures are outside the built-in field declarations exercised by Router/client tests. A non-Buffered body at the buffered multipart finisher is excluded by dispatch staging; optional's non-object schema fallback is defensive for custom codecs. |
| mttp_core/src/client/client.mbt | 1 | Defensive arm: `guard_retry` refuses a future `Decision` constructor, which cannot be built in this release, as `Stop(NotRetryable)`. |
| mttp_core/src/client/response_as.mbt | 2 | Forward-compatible Body arm in the diagnostic excerpt: a future body representation cannot be built in this release and is refused as `Invalid` rather than read as empty (buffering is `Body::read_all` in the root package, which matches every arm). The prepared reader's placeholder abort is unreachable because Client always replaces it by its preparation result before reading. |
| mttp_core/src/client/curl.mbt | 1 | Forward-compatible Body arm: a future body representation is omitted from the diagnostic without being read; every current variant has a test. |
| mttp_core/src/client/events.mbt | 1 | Forward-compatibility arm of the `#non_exhaustive` `Kind` match naming a retry's reason: every kind the module defines has its own name, tested in `events_wbtest.mbt`. |
| mttp_core/src/schema/collection.mbt | 1 | Encoding precondition: encoding through a recursive codec inside its own construction body aborts, as the codec it delegates to does not exist yet; decoding there is a tested `Malformed`. |
| mttp_core/src/schema/decoder.mbt | 1 | Saturation of the default step budget for an input of more than 8 388 607 JSON values, which keeps 256 steps per value from overflowing `Int`; reaching it needs a tree of that size in memory. |
| mttp_core/src/schema/primitives.mbt | 1 | Defensive arm: `double` checks decimal syntax first, which has no `inf` or `NaN`, and `@string.parse_double` raises on overflow, so the finite check cannot fail. |
| mttp_core/src/schema/union.mbt | 3 | Encoding preconditions: exhaustive case projections and object payload encoders for tagged unions. Violating them is an application definition error that aborts; all untrusted-input decoding paths return tested structured errors. |
| mttp_core/src/endpoint/client_interp.mbt | 6 | Defensive alternatives after head selection: decode_reply cannot find no candidate; an error-only branch cannot decode success; a streaming branch always has a stream decoder; any_status cannot produce the reader's status rejection. Unknown buffered-decoder exception arms preserve future decoder effects; current public codecs raise only DecodeFailure, translated to DecodeError. Overlapping output/error fallback is covered by review_regression_test.mbt. |
| mttp_core/src/endpoint/dynamic_output.mbt | 2 | Named-cookie selection filters on the exact name prefix before decoding, so neither the subsequent prefix guard nor its decoding-error catch can fail. Missing and repeated named cookies are covered. |
| mttp_core/src/endpoint/input.mbt | 3 | BodyValue alternatives in raw_body, stream_body and buffered body finishers: dispatch supplies the representation their staged metadata requested, so the other alternatives cannot reach these built-in finishers. External custom finishers and the absence checks are covered. |
| mttp_core/src/endpoint/output.mbt | 6 | A deterministic partial projection that matched cannot become None during status selection or encoding. Buffered decoding cannot select a stream-only variant because request requires Buffered, and current public body/header codecs cannot raise unknown decoder exceptions. Negotiation's forward-compatible MediaChoice arm cannot be constructed in this release. Empty candidate sets, dynamic encoder cleanup on malformed Accept, unacceptable media and invalid dynamic statuses are covered by Router tests. |
| mttp_core/src/endpoint/server.mbt | 3 | Forward-compatible Body arm in streaming input: a future body constructor cannot be built in this release and is rejected as Malformed rather than passed to a handler. All three current body representations are covered. |
| mttp_core/src/router/router.mbt | 2 | Forward-compatible Seg arm: endpoint parsing currently constructs only Lit, Cap and Rest, all covered by routing tests. A future segment kind is refused rather than routed. The abort in `Router::must` runs only in its `panic` test, which records no coverage. |
| mttp_core/src/router/session.mbt | 1 | Forward-compatible SameSite arm defaults to Lax. The current cookie package constructs only Strict, Lax and NoRestriction; all three are exercised by Router session tests. |
| mttp_core/src/openapi/openapi.mbt | 3 | Forward-compatible AuthScheme arm: every current authentication kind, including Signature as a parameter, is covered. Future authentication kinds are refused; they cannot be constructed in this release. Path rendering now belongs to endpoint and covers every current segment kind. |

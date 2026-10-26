# Test coverage ledger

Line coverage of `gaato/mttp`, measured on native with
`moon test --enable-coverage` and reported in Coveralls-JSON mode. The rule is
a closed ledger:

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

### What is measured

- Sources: every non-test `.mbt` under `mttp/src/`.
- Test drivers: every package of `gaato/mttp`.
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

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

Must be covered by tests:

- pure logic: header, URL and body assembly, the parsers, retry and
  rate-limit arithmetic, the client loop;
- every `raise` arm reachable through the public API.

Accepted as uncovered (needs a row):

- defensive arms that are unreachable by construction;
- platform-only fallbacks that native never takes;
- testable lines not yet tested, marked `not yet tested`: these are the
  queue for new tests, not a permanent exemption.

Budgets are exact uncovered counts at the last measurement.

## Accepted uncovered

| File | Budget | Reason |
| --- | --- | --- |
| mttp-net/src/internal/h1client/upload.mbt | 3 | Empty-body upload arm is bypassed by exchange's completed-head fast path; forward-compatible Body arm; defensive result guard requires a Coordination implementation to return without running its primary callback, contrary to the port contract. |
| mttp/src/client/curl.mbt | 1 | Forward-compatible Body arm: future body variants are omitted from diagnostics without being read; all current variants have tests. |
| mttp/src/client/client.mbt | 2 | A Timer returning success without invoking its callback violates the Timer contract; the guard refuses it. The other arm refuses future Decision constructors that cannot be built in this release. |
| mttp/src/client/response_as.mbt | 2 | Forward-compatible Body arms in successful buffering and error excerpts: current constructors are covered, and future unsupported bodies raise Invalid rather than returning empty data. |
| mttp/src/multipart/multipart.mbt | 1 | Forward-compatible Body arm: a future body representation cannot be constructed in this release and is refused as an unsupported part. |
| mttp-net/src/codings/encoded_body.mbt | 1 | Defensive open-error conversion: the private source callback and encoder raise TransportError, handled first. Cancellation propagates as a signal. |
| mttp-net/src/internal/h1server/request_body.mbt | 2 | Defensive open-error conversion after timeout and TransportError cases; NoBody is already done and request framing never produces UntilClose or future variants. |
| mttp-net/src/internal/h1server/response.mbt | 1 | Forward-compatible EncodingChoice arm; all current negotiation results are handled first. |
| mttp-net/src/server/serve.mbt | 9 | Not yet forced in the physical listener: late accept/background/task handoffs during shutdown, unexpected accept-task cancellation and open-error cleanup fallbacks. The corresponding pure event orders and close/cancel action interpreter are tested in control/control_test.mbt and server/lifecycle_wbtest.mbt; real listener tests cover graceful completion, expiry, caps and accept failure. |
| mttp/src/endpoint/client_interp.mbt | 5 | Head selection and decoding use the same immutable variants, so no-match, a successful output in the declared-error-only branch, and a declared error after a selected output decoder cannot occur. The any_status stream wrapper cannot produce its outer rejection value. The open-error rethrow is defensive: current byte decoders only raise the handled private DecodeError/schema DecodeFailure. Real malformed data, declared errors and user stream callback exceptions have tests. |
| mttp/src/endpoint/dynamic_output.mbt | 2 | Named-cookie prefix guard and its conversion catch: the private selector filters for that exact prefix before invoking the codec; that codec has no other failure path. |
| mttp/src/endpoint/input.mbt | 3 | Defensive wrong BodyValue arms: the server chooses Buffered for raw and buffered inputs and Streamed for streaming inputs; these private staged decoders cannot receive the opposite representation through dispatch. |
| mttp/src/endpoint/output.mbt | 4 | Two projection guards require a nondeterministic projection, contrary to the documented contract. Byte-decoder open-error rethrow is defensive because current public codecs raise only handled decoding signals. A streaming-only variant cannot reach the private byte decoder through the typed public API; negative type fixtures enforce this boundary. |
| mttp/src/endpoint/server.mbt | 3 | Rejects future non-exhaustive Body variants as malformed input; those variants cannot be constructed in this release. Authentication Err, missing declared-error projections and the outer handler error policy have tests. |
| mttp/src/openapi/openapi.mbt | 4 | Forward-compatible AuthScheme and Seg arms: all currently constructible variants are handled before these non-exhaustive fallback arms. |
| mttp/src/router/router.mbt | 1 | Forward-compatible Seg arm: every currently constructible segment is handled before this fallback. |
| mttp/src/router/ownership.mbt | 1 | Defensive closed-reader guard: the enclosing taken stream returns EOF after close before invoking this private response owner again. Public EOF, failure, cancellation and repeated close paths are tested. |
| mttp-net/src/internal/h1client/target.mbt | 1 | Defensive URL-parse conversion: Request.validate has already parsed and accepted the same immutable URL before target construction. |
| mttp-net/src/internal/h1client/response_body.mbt | 2 | Defensive NoBody and future-framing arms: send returns Empty for NoBody, and the current h1 response framing function cannot produce future constructors. |
| mttp-net/src/runtime/timer.mbt | 1 | Defensive conversion required by the runtime task-group API's open error type: ClockTimer accepts a nonraising callback and Clock.sleep is nonraising. Parent cancellation propagates as a signal, verified by the cancellation test, and cannot enter this ordinary-error catch. |
| mttp/src/schema/union.mbt | 3 | Encoding preconditions: exhaustive case projections and object payload encoders for tagged unions. Violating them is an application definition error that aborts; all untrusted-input decoding paths return tested structured errors. |
| mttp/src/multipart/stream_body.mbt | 1 | Defensive closed-reader guard: the enclosing taken stream returns EOF before delegating again, so this branch cannot be reached through the public body API. |
| mttp/src/testing/driver/driver.mbt | 2 | Defensive foreign-runtime suspension fallback (core links no async runtime), and cancel_and_join invoked without an active task on its own Driver. Structured cleanup calls it only while that Driver is stepping a task. |
| mttp-net/src/conn/socket.mbt | 2 | Not yet tested: abrupt TLS read/write errors after a verified handshake. Handshake refusal, nested verified TLS, normal traffic, close idempotency and operations after close are tested. Runtime-error translation itself has a focused boundary test. |
| mttp-net/src/internal/h1client/timeouts.mbt | 1 | A conforming Timer returns true only after its callback completes; that callback always stores a Result. The missing-result guard protects against a faulty injected Timer. |
| mttp-net/src/internal/h1server/wire.mbt | 3 | Missing-result guard for a faulty Timer, and open-error conversion after the TransportError arm. Conn writes raise only TransportError and cancellation is a signal; generic timeout orchestration must still support parser errors elsewhere. |
| mttp-net/src/runtime/coordination.mbt | 3 | Defensive open-error Task.wait and task-group conversions. Both callbacks' TransportErrors are captured; the only other expected exit is uncatchable parent cancellation, covered by cleanup tests. |
| mttp/src/testing/conn/coordination.mbt | 2 | Defensive Task.wait catches: both spawned callbacks capture their declared TransportErrors. Driver cancellation returns false or propagates as a signal rather than an ordinary Error. |

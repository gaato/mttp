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
| mttp-net/src/backend/upload.mbt | 1 | Forward-compatible Body arm: every currently constructible body variant is handled first; future unsupported bodies are rejected instead of being written as empty uploads. |
| mttp/src/client/curl.mbt | 1 | Forward-compatible Body arm: future body variants are omitted from diagnostics without being read; all current variants have tests. |
| mttp/src/client/response_as.mbt | 2 | Forward-compatible Body arms in successful buffering and error excerpts: current constructors are covered, and future unsupported bodies raise Invalid rather than returning empty data. |
| mttp/src/multipart/multipart.mbt | 1 | Forward-compatible Body arm: a future body representation cannot be constructed in this release and is refused as an unsupported part. |
| mttp-net/src/codings/encoded_body.mbt | 1 | Defensive open-error conversion: the private source callback and encoder raise TransportError, handled first. Cancellation propagates as a signal. |
| mttp-net/src/server/request_body.mbt | 2 | Defensive open-error conversion after timeout and TransportError cases; NoBody is already done and request framing never produces UntilClose or future variants. |
| mttp-net/src/server/response.mbt | 1 | Forward-compatible EncodingChoice arm; all current negotiation results are handled first. |
| mttp-net/src/server/connection.mbt | 1 | Defensive task error propagation: respond handles current ordinary failures, and cancellation has its own case. |
| mttp-net/src/server/serve.mbt | 6 | Not yet tested: shutdown/accept race guards and open-error fallbacks around nested task groups. Public accept failure, graceful completion, grace expiry, connection cap and cancellation are tested; deterministic injection of these remaining interleavings is pending. |
| mttp/src/endpoint/client_interp.mbt | 2 | Defensive no-variant guards: accept_head already selected from the same immutable output variants and response head before either reader runs. Decoder failures raise instead of returning no match. |
| mttp/src/endpoint/dynamic_output.mbt | 1 | Named-cookie prefix guard: the private selector filters for that exact prefix before invoking its decoder. |
| mttp/src/endpoint/input.mbt | 3 | Defensive wrong BodyValue arms: the server chooses Buffered for raw and buffered inputs and Streamed for streaming inputs; these private staged decoders cannot receive the opposite representation through dispatch. |
| mttp/src/endpoint/output.mbt | 2 | Projection precondition guards: encoding and dynamic status selection follow a successful matches call. Reaching these arms requires a nondeterministic projection, contrary to the documented variant contract. |
| mttp/src/endpoint/server.mbt | 4 | Three lines reject future non-exhaustive Body variants as malformed input; those variants cannot be constructed in this release. One defensive outer pipeline catch remains: current authenticate/handle errors and staged InputErrors are classified inside their calls. |
| mttp/src/openapi/openapi.mbt | 4 | Forward-compatible AuthScheme and Seg arms: all currently constructible variants are handled before these non-exhaustive fallback arms. |
| mttp/src/router/router.mbt | 1 | Forward-compatible Seg arm: every currently constructible segment is handled before this fallback. |
| mttp/src/router/ownership.mbt | 1 | Defensive closed-reader guard: the enclosing taken stream returns EOF after close before invoking this private response owner again. Public EOF, failure, cancellation and repeated close paths are tested. |
| mttp-net/src/backend/target.mbt | 1 | Defensive URL-parse conversion: Request.validate has already parsed and accepted the same immutable URL before target construction. |
| mttp-net/src/backend/response_body.mbt | 2 | Defensive NoBody and future-framing arms: send returns Empty for NoBody, and the current h1 response framing function cannot produce future constructors. |
| mttp-net/src/runtime/timer.mbt | 1 | Defensive conversion required by the runtime task-group API's open error type: ClockTimer accepts a nonraising callback and Clock.sleep is nonraising. Parent cancellation propagates as a signal, verified by the cancellation test, and cannot enter this ordinary-error catch. |
| mttp/src/schema/union.mbt | 3 | Encoding preconditions: exhaustive case projections and object payload encoders for tagged unions. Violating them is an application definition error that aborts; all untrusted-input decoding paths return tested structured errors. |
| mttp/src/multipart/stream_body.mbt | 1 | Defensive closed-reader guard: the enclosing taken stream returns EOF before delegating again, so this branch cannot be reached through the public body API. |
| mttp/src/testing/driver/driver.mbt | 1 | Defensive arm, unreachable by construction in `gaato/mttp`: `step` marks a task parked when it suspended through something other than its driver, which needs an async runtime the module does not link. |

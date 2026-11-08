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

### What is measured

- Sources: every non-test `.mbt` under `<module>/src/` of every module.
- Test drivers: every package of those modules.
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
  rate-limit arithmetic, the client loop, the connection engines;
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
| http/src/driver/driver.mbt | 1 | Defensive arm: a task suspended by something other than its Driver. No async runtime is linked, so nothing else can suspend it. |
| http/src/h1client/client.mbt | 1 | Forward-compatibility arm of the `#non_exhaustive` `BodyTiming` match: every timing the module defines has its own arm. |
| http/src/h1client/failure.mbt | 3 | Defensive arm: an error that is neither a `TransportError` nor a codec `ParseError`. The ports raise only `TransportError`, and every codec call inside a phase raises `ParseError`; cancellation is not an `Error`. |
| http/src/h1client/proxy.mbt | 1 | Defensive arm: the CONNECT head refused by the wire writer. Its fields are the origin's authority, the proxy's credentials and the User-Agent of a request whose own head was already written. |
| http/src/h1client/response_body.mbt | 1 | Defensive arm: a `NoBody` framing in the body reader. A response without a body is returned with `Body::Empty` and never gets a reader. |
| http/src/h1client/timeouts.mbt | 1 | Overflow guard of the time left: it needs the clock to move back by more than 2^63 ms after the deadline was set. |
| http/src/h1client/upload.mbt | 1 | Defensive arm: a concurrent exchange that returns without a final head. Its primary returns normally only after one arrived; every other ending raises or is cancellation. |
| http/src/sim/contracts.mbt | 2 | Defensive arms: `check_coordination_contract` requiring the outer supervision to raise its monitor's failure after a nested one was cancelled (the earlier monitor-failure step already requires it, and cancellation cannot be caught, so a nested supervision cannot turn into a normal return that would hide it); and the read of the stream `check_backend_contract` attaches with a negative declared length, which `StreamBody::take` refuses, so no backend can read it. |
| mttp/src/multipart/multipart.mbt | 1 | Forward-compatible Body arm: a future body representation cannot be constructed in this release and is refused as an unsupported part. |
| mttp/src/multipart/stream_body.mbt | 1 | Defensive closed-stream guard: the `StreamBody` wrapping the multipart stream returns EOF once closed, before delegating again, so this branch cannot be reached through the public body API. |
| mttp/src/client/client.mbt | 1 | Defensive arm: `guard_retry` refuses a future `Decision` constructor, which cannot be built in this release, as `Stop(NotRetryable)`. |
| mttp/src/client/response_as.mbt | 3 | Forward-compatible Body arms in buffering and in the diagnostic excerpt: a future body representation cannot be built in this release and is refused as `Invalid` rather than read as empty. The prepared reader's placeholder abort is unreachable because Client always replaces it by its preparation result before reading. |
| mttp/src/client/curl.mbt | 1 | Forward-compatible Body arm: a future body representation is omitted from the diagnostic without being read; every current variant has a test. |
| mttp/src/schema/collection.mbt | 1 | Encoding precondition: encoding through a recursive codec inside its own construction body aborts, as the codec it delegates to does not exist yet; decoding there is a tested `Malformed`. |
| mttp/src/schema/decoder.mbt | 1 | Saturation of the default step budget for an input of more than 8 388 607 JSON values, which keeps 256 steps per value from overflowing `Int`; reaching it needs a tree of that size in memory. |
| mttp/src/schema/primitives.mbt | 1 | Defensive arm: `double` checks decimal syntax first, which has no `inf` or `NaN`, and `@string.parse_double` raises on overflow, so the finite check cannot fail. |
| mttp/src/schema/union.mbt | 3 | Encoding preconditions: exhaustive case projections and object payload encoders for tagged unions. Violating them is an application definition error that aborts; all untrusted-input decoding paths return tested structured errors. |
| mttp/src/endpoint/client_interp.mbt | 6 | Defensive alternatives after head selection: decode_reply cannot find no candidate; an error-only branch cannot decode success; a streaming branch always has a stream decoder; any_status cannot produce the reader's status rejection. Unknown buffered-decoder exception arms preserve future decoder effects; current public codecs raise only DecodeFailure, translated to DecodeError. Overlapping output/error fallback is covered by review_regression_test.mbt. |
| mttp/src/endpoint/dynamic_output.mbt | 2 | Named-cookie selection filters on the exact name prefix before decoding, so neither the subsequent prefix guard nor its decoding-error catch can fail. Missing and repeated named cookies are covered. |
| mttp/src/endpoint/input.mbt | 3 | BodyValue alternatives in raw_body, stream_body and buffered body finishers: dispatch supplies the representation their staged metadata requested, so the other alternatives cannot reach these built-in finishers. External custom finishers and the absence checks are covered. |
| mttp/src/endpoint/output.mbt | 4 | A deterministic partial projection that matched cannot become None during status selection or encoding. Buffered decoding cannot select a stream-only variant because request requires Buffered, and current public body/header codecs cannot raise unknown decoder exceptions. |
| mttp/src/endpoint/server.mbt | 3 | Forward-compatible Body arm in streaming input: a future body constructor cannot be built in this release and is rejected as Malformed rather than passed to a handler. All three current body representations are covered. |
| mttp/src/router/router.mbt | 1 | Forward-compatible Seg arm: endpoint parsing currently constructs only Lit, Cap and Rest, all covered by routing tests. A future segment kind is refused rather than routed. |
| mttp/src/openapi/openapi.mbt | 4 | Forward-compatible AuthScheme and Seg arms: every current authentication kind (including Signature as a parameter) and path segment kind is covered. Future authentication kinds are refused and future segments omitted; they cannot be constructed in this release. |

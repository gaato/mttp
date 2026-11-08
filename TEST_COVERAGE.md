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
| http-async/src/conn/dialer.mbt | 1 | Forward-compatible Trust arm: Trust now belongs to the cross-target root package, so the dialer must refuse future constructors that cannot be constructed in this release. |
| http-async/src/conn/conn_io.mbt | 1 | BinaryWriterImpl::get_controller is not called by core's current writer defaults; the controller is a stateless marker reserved for future buffering/locking. Each bridge still constructs and owns its controller as required by the core trait. |
| http-async/src/codings/body_source.mbt | 1 | Forward-compatible Body arm: a future body representation is refused instead of silently treated as empty. |
| http-async/src/codings/decompress.mbt | 1 | Defensive fallback for a non-TransportError from read_decoded: this wrapper supplies a TransportError-only reader and ContentDecoder translates codec errors to TransportError. Cancellation is a scheduler signal. |
| http-async/src/codings/encoded_body.mbt | 1 | Defensive fallback for a non-TransportError from read_encoded: this wrapper supplies a TransportError-only reader and ContentEncoder translates codec errors to TransportError. |
| http-async/src/internal/socketconn/socket.mbt | 2 | Not yet tested: reentrant close between spawning a directional child and registering its cancellation handle. The defensive checks remain because TaskGroup::spawn allows a child to start immediately. Ordinary pending read/write close and caller cancellation are tested. |
| http-async/src/runtime/coordination.mbt | 3 | Defensive Task::wait rethrow and non-TransportError mapping: primary/monitor raise only TransportError, primary errors are recorded before wait returns, and explicit child cancellation has its own arm. |
| http-async/src/runtime/timer.mbt | 1 | Defensive ordinary-error fallback of the generic timeout helper. Clock::sleep and Timer's callback are noraise, so current children cannot raise an Error; cancellation propagates independently. |
| http/src/driver/driver.mbt | 1 | Defensive arm: a task suspended by something other than its Driver. No async runtime is linked, so nothing else can suspend it. |
| http/src/h1client/client.mbt | 1 | Forward-compatibility arm of the `#non_exhaustive` `BodyTiming` match: every timing the module defines has its own arm. |
| http/src/h1client/failure.mbt | 3 | Defensive arm: an error that is neither a `TransportError` nor a codec `ParseError`. The ports raise only `TransportError`, and every codec call inside a phase raises `ParseError`; cancellation is not an `Error`. |
| http/src/h1client/proxy.mbt | 1 | Defensive arm: the CONNECT head refused by the wire writer. Its fields are the origin's authority, the proxy's credentials and the User-Agent of a request whose own head was already written. |
| http/src/h1client/response_body.mbt | 1 | Defensive arm: a `NoBody` framing in the body reader. A response without a body is returned with `Body::Empty` and never gets a reader. |
| http/src/h1client/timeouts.mbt | 1 | Overflow guard of the time left: it needs the clock to move back by more than 2^63 ms after the deadline was set. |
| http/src/h1client/upload.mbt | 1 | Defensive arm: a concurrent exchange that returns without a final head. Its primary returns normally only after one arrived; every other ending raises or is cancellation. |
| http/src/h1server/request_body.mbt | 2 | Defensive guards: retrying an already failed private body cursor (the public acquired reader closes after failure, and the session refuses reuse before draining a failed cursor), and draining while still owing 100 Continue (the response is already marked Connection: close, which skips drain). |
| http/src/h1server/response.mbt | 1 | Forward-compatible Body arm: a future response body representation cannot be constructed in this release and is refused as Invalid before writing a head. |
| http/src/sim/contracts.mbt | 2 | Defensive arms: `check_coordination_contract` requiring the outer supervision to raise its monitor's failure after a nested one was cancelled (the earlier monitor-failure step already requires it, and cancellation cannot be caught, so a nested supervision cannot turn into a normal return that would hide it); and the read of the stream `check_backend_contract` attaches with a negative declared length, which `StreamBody::take` refuses, so no backend can read it. |
| mttp/src/multipart/multipart.mbt | 1 | Forward-compatible Body arm: a future body representation cannot be constructed in this release and is refused as an unsupported part. |
| mttp/src/multipart/stream_body.mbt | 1 | Defensive closed-stream guard: the `StreamBody` wrapping the multipart stream returns EOF once closed, before delegating again, so this branch cannot be reached through the public body API. |
| mttp/src/client/client.mbt | 1 | Defensive arm: `guard_retry` refuses a future `Decision` constructor, which cannot be built in this release, as `Stop(NotRetryable)`. |
| mttp/src/client/response_as.mbt | 2 | Forward-compatible Body arms in buffering and in the diagnostic excerpt: a future body representation cannot be built in this release and is refused as `Invalid` rather than read as empty. |
| mttp/src/client/curl.mbt | 1 | Forward-compatible Body arm: a future body representation is omitted from the diagnostic without being read; every current variant has a test. |

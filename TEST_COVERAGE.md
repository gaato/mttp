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
| http/src/driver/driver.mbt | 2 | Defensive arms: a task suspended by something other than its Driver (no async runtime is linked, so nothing else can suspend it), and `cancel_and_join` called with no task of its own Driver running, where it only requests cancellation. Structured cleanup calls it only while that Driver is stepping a task. |
| http/src/sim/contracts.mbt | 2 | Defensive arms: `check_coordination_contract` requiring the outer supervision to raise its monitor's failure after a nested one was cancelled (the earlier monitor-failure step already requires it, and cancellation cannot be caught, so a nested supervision cannot turn into a normal return that would hide it); and the read of the stream `check_backend_contract` attaches with a negative declared length, which `StreamBody::take` refuses, so no backend can read it. |

# Resource bounds

What a long-running client, server or parser built on `gaato/mttp` can
accumulate, and what keeps each structure from growing without limit. The
rule: **every structure that grows with input from the network, a peer, or
the number of requests, buckets, connections or pending calls is listed here
with its bound**. A new one, such as a map keyed by names that arrive from
outside or a buffer filled from a stream, needs a row before it ships.

A bound is either a limit the code enforces, or the rate of the input times
how long an entry lives, where both are themselves bounded. Rows of the second
kind say what that product is. Bounded by default: a limit has a default, and
input past it is refused rather than degraded.

**Every row of "Enforced limits" names a test that checks the bound**, in its
Tests column: a backticked file path, then the quoted names of that file's
tests, as in `` `mttp/src/sse/parser_test.mbt`: "first", "second" ``. A test
counts only if it drives the structure to its limit and one past it, or pins a
default the row states; one that merely uses the feature does not.
`scripts/bounds_check.mbtx`, run by `scripts/gates.sh`, enforces the naming: it
fails when a row names no test or a named test is not declared in the named
file. Whether a named test really reaches the bound is checked in review. The
other tables describe where no limit is enforced, so they stay prose.

Scope: every package of `gaato/mttp`. Test helpers (`testing`, `clock/fake`)
record what a test feeds them and are not listed, except the limits that keep
a test from hanging (the `testing/driver` rows).

## Enforced limits

| Structure | Bound | On overflow | Tests |
|---|---|---|---|
| `sse` retained event fields and unfinished line | `max_event_bytes`, default 16 MiB | Refuses with `TooLarge`; already completed events in the same chunk are delivered before the pending error | `mttp/src/sse/parser_test.mbt`: "one event is bounded by the lines it keeps plus the line being read", "the default bound is 16 MiB" |
| `model` buffered stream read | Explicit `read_bounded` limit | Closes the stream and raises at the crossing chunk | `mttp/src/model/body_test.mbt`: "read bounded accepts exact limit and closes at crossing chunk" |
| `testing/driver` steps of one `Driver::run` (and of manual `step` calls since it started) | `max_steps`, default 100 000 000 | `step` raises `DriverError(NoQuiescence(steps~))`; `run` cancels and unwinds the live tasks first | `mttp/src/testing/driver/driver_test.mbt`: "max_steps allows exactly that many steps per run", "livelock raises NoQuiescence" |
| `testing/driver` rounds of cancellation when `run` ends | `max_unwind_rounds` = 8 | `run` raises `DriverError(UnwindIncomplete(live~))`; the surviving tasks stay live | `mttp/src/testing/driver/driver_test.mbt`: "unwinding gives up after max_unwind_rounds rounds" |
| `testing/driver` timer callbacks per run | `max_steps`, independent of task steps | Raises `NoQuiescence`, discards timers and cancels live tasks | `mttp/src/testing/driver/driver_test.mbt`: "self-rearming due timers obey a callback budget" |
| `testing/driver` cleanup steps per cancellation round | Maximum of `max_steps` and twice the number of live tasks at round start | Ends the round; at most eight rounds | `mttp/src/testing/driver/driver_test.mbt`: "exhausted execution budget still unwinds ten thousand tasks", "unwinding gives up after max_unwind_rounds rounds" |

## Bounded by rate and lifetime

| Structure | Grows with | Bound |
|---|---|---|

## Left to the caller

Growth that follows what the caller asks for, not what the network sends.

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| `model` headers, URL strings, attribute maps and byte bodies | Values explicitly constructed by the caller | Parsers and backends impose network input limits; these value constructors do not consume network input. |
| `multipart` framing and part descriptors | Caller-supplied parts | Streaming retains framing plus the supplied byte bodies and stream handles; boundary scanning retains at most the delimiter length. |
| `testing/driver` ready queue, live-task map, timer heap | tasks the test spawns and timers it arms | A test helper: the test decides how many; `max_steps` stops a run that keeps spawning. Cancelled timers stay in the heap until they reach its top or `run` ends. |

## Known gaps

Growth the library does not bound yet, with what limits it in practice and how
it could be fixed.

| Structure | Grows with | What limits it | Suggested fix |
|---|---|---|---|

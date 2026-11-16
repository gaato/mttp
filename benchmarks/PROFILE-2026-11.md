# Small-response server profile — 2026-11-16

Original investigation of `8e6715c`, native release, `MOON_CC=cc`. No production
code, API, dependency, or test changes were made during that investigation.
Its two experiments ran in a disposable source copy. The V15a direct-body
implementation and V15b receive-storage/write-coalescing follow-ups are
recorded below.

## Method and reproduction

This is the small-server subset of `scripts/gates.sh bench`: the existing
`benchmarks/transport/main.mbt` server, the same pinned oha image and options,
HTTP/1.1 loopback, keep-alive, GET `/small`, 15 response body bytes, 32 connections,
10 seconds. Each original server passed the executable's exact-body `check`;
successful load runs reported only 200s and no request errors. The oha request
head is 129 bytes (including its default accept/encoding/user-agent headers).

Machine: i5-10400F, 6 cores / 12 threads, Linux 7.3.1-1-default x86_64,
host glibc 2.44. Toolchain: moon 0.1.20261104 (940aa18), moonc
0.10.20+65efd5b93, moonrun 0.1.20261104. A writable copy of that toolchain and
`XDG_CONFIG_HOME` were used below `/var/tmp/mttp-plan/scratch/v15`.

Representative commands (from the worktree root, after configuring that
toolchain's PATH and MOON_HOME):

```sh
MOON_CC=cc moon run benchmarks/transport --target native --release -- build
_build/native/release/build/gaato/mttp-transport-bench/mttp-transport-bench.exe \
  server mttp 127.0.0.1:39165
# Substitute core to measure the comparison server, after stopping mttp.
docker run --rm --network host \
  ghcr.io/hatoo/oha:1.15@sha256:57c2247792c1466c88ecc83ddb9253aa0b58dcb852b1d7f2026a0acf7744c965 \
  -z 10s -c 32 --http-version 1.1 --no-tui --output-format json \
  --wait-ongoing-requests-after-deadline http://127.0.0.1:39165/small
```

| Original server | requests | req/s | p50 ms | p99 ms |
|---|---:|---:|---:|---:|
| mttp | 108,614 | 10,855.6 | 2.915 | 4.246 |
| core/async/http | 618,288 | 61,811.6 | 0.491 | 0.734 |

The 5.69x gap reproduces the README's 5.78x gap. The first three mttp controls
were 10,855.6, 10,078.3 and 11,165.6 req/s; a later control fell to 2,075.2
req/s while native gates were building. This is a shared host, without CPU
affinity. These controls demonstrate that throughput deltas cannot be assigned
entirely to the scratch changes. Instruction/call counts are stronger evidence
for those hypotheses than their wall-time deltas. Other body
sizes, client rows, Go and Node were outside this profiling subset.

`perf record` with both `cpu-clock:u` and `task-clock:u` was denied by the
environment (perf_event_paranoid=2 / capability restrictions). Instead, the
**unchanged native release executable** ran under Callgrind 3.19.0, with the
same 32-connection oha load, fixed at 2,000 successful requests. These profiles
count user-space instructions (Ir), not sampled CPU cycles or wall-time
percentages. Callgrind and Memcheck ran in a disposable container based on
`python@sha256:b685a4fa58bb19d1814d78a1ec0f0208f351452724f78b20212c984d6e124a34`,
with Debian valgrind `1:3.19.0-1`, glibc `2.36-9+deb12u14`. Nothing was installed
on the host. Profiles compare the same executable and container libc; do not
interpret their allocator percentages as host glibc cycle percentages.

For mttp, counters were reset before the measured load and dumped after its
completion. Core's profile includes initialization and one exact-body check
(2,001 responses); its startup-only profile was 2.68M Ir, about 1.3% of its
total. Reset/dump can leave zero-call ancestor entries with inclusive costs in
Callgrind output: the reported self costs below exclude those synthetic
`(below main)` / libc-start entries. Inclusive costs overlap and must not be
added together.

Syscalls were measured separately on the host with `strace -f -c`, 20,000
requests per server; a short full trace of 320 requests established write
sizes. Launching the server under `strace ... timeout -s TERM ...` allowed
strace to flush its summary. Startup/timeout/signal-thread syscalls are in the
raw totals, but **the timeout wrapper's wait/signal times and its one POSIX
timer are not server costs**. Traced throughput is not used as a performance
result. Memcheck allocation totals came from separate 2,000-request runs and
normal SIGTERM termination, not forced termination of the profiler.

## Per-request comparison

| Measure | mttp | core/async/http |
|---|---:|---:|
| Callgrind total Ir / completed response | 590,124 | 106,143 (startup included) |
| Memcheck total heap allocation calls | 2,982,220 | 574,637 |
| Allocation calls / request, subtracting common startup | ≈1,491 | ≈287 |
| Total allocated bytes | 236,506,092 | 27,910,616 |
| Allocated bytes / request, subtracting common startup | 117,575 | 13,278 |
| TaskGroup coroutine creations during profiled load | 38,160 / 2,000 | 34 / 2,001 |
| Steady task creations / request | ≈19 | 0 (tasks are per connection) |
| Deadline timers started during profiled load | 10,032 / 2,000 | 0 per request |
| Host `read` calls / 20,000 requests | 40,040 | 20,042 |
| `read` errors, overwhelmingly EAGAIN | 20,001 | 3 |
| Host `write` calls / 20,000 requests | 40,003 | 20,003 |
| `epoll_wait` calls / 20,000 requests | 18,181 | 1,277 |
| `epoll_ctl` calls / 20,000 requests | 67 | 67 |
| Approx. read + write + epoll_wait calls / request | 4.91 | 2.07 |
| Response writes | 116-byte head, then 15-byte body | one 131-byte write |
| Mean response bytes / socket write | 65.5 | 131 |

The common startup-only Memcheck run was 291 allocations / 1,355,119 bytes.
The adjusted figures still include connection establishment/teardown, so they
are approximate per-request averages, not a claim of an exact object count
for every exchange. Allocated bytes are cumulative traffic, **not retained
heap or a leak**. Both Memcheck runs reported zero memory-error contexts;
leak checking was disabled.

The successful socket reads are approximately one per request for both.
mttp adds approximately one unsuccessful read: the peer monitor speculatively
reads the next request, waits for input, then is cancelled/joined as the
exchange completes. Which coroutine obtains the next head is scheduling
dependent. `epoll_wait` frequency also depends on load and scheduling; it is
not a protocol requirement. The equal `epoll_ctl` counts are registration at
connection setup/teardown, not re-registration for every timer.

## Where the work goes

1. **Fine-grained structured async work and object destruction.** On mttp,
   `_int_free` is 18.70% self Ir, `moonbit_drop_object` 15.76%, `malloc` 10.57%,
   `scan_regular_object` 6.77%, `_int_malloc` 5.37%, and `free` 5.31%: together
   **62.48%**. Core has a similar percentage in those routines, but performs
   about one fifth as many allocations and 5.56x fewer instructions/response.
   This is chiefly more work, not evidence that the mttp allocator itself is
   different from core's. Runtime rescheduling is 99.6% inclusive in mttp,
   because almost all application work runs under it; that number alone does
   not mean 99.6% scheduling overhead.

   The source explains the measured ≈19 coroutine creations/req:
   five deadline scopes × two tasks (the group callback itself is a task,
   plus its sleeping timer); one supervise scope × three tasks (group
   callback, primary, monitor); approximately one socket read × two tasks;
   two socket writes × two tasks. Connection setup/closure accounts for the
   small residual. Core's handler and I/O stay in the connection task.

2. **A fixed body takes the streaming path.** `server/response.mbt::lease`
   wraps every response body in `ResponseLease` / `StreamBody` so that
   graceful shutdown knows when the response has finished. A 15-byte Bytes
   response therefore requires a timed first pull and a timed EOF pull,
   in addition to the header-read timer and two write timers: **five timers
   instead of three**. The default handler timeout is `None`; it is not a
   sixth timer. The profile confirms 10,032 timer starts for 2,000 requests.
   The lease preserves the known length: this response still uses
   `Content-Length: 15`, so chunk framing is not the source of extra writes.
   Timers are core/async's user-space sorted-set entries plus epoll timeout
   selection, not one timerfd syscall per deadline.

3. **A 64 KiB zero-filled receive buffer for a 129-byte head.**
   `internal/socketconn/socket.mbt::read` allocates
   `FixedArray::make(max_len.min(65536), 0)` before its child read.
   `moonbit_make_bytes` is 12.85% inclusive Ir; `memset` alone is **11.36% self
   Ir** versus 0.71% in core's startup-inclusive profile. There are 2,032
   buffer creations for the monitored-read branch in the mttp load, already
   about 66.6 kB zeroed per completed request. This explains much of the
   117.6 kB/req allocation traffic. Core keeps its I/O reader buffer across
   requests. Small bodies do not benefit from mttp's 64 KiB bulk transfers.

4. **Two immediate writes with independent async/deadline scopes.**
   `h1server/response.mbt` writes the head and body separately; `Wire::write`
   copies each bounded slice, enters a deadline scope, and `SocketConn::write`
   enters another task group. The TCP writer is unbuffered: mttp has no
   additional per-request explicit flush to blame. Core's `Sender` buffers
   the head and small body and flushes them at `end_response` as one write.
   Both use TCP_NODELAY. The extra write is proved by the full trace, but
   eliminating one syscall alone cannot explain a 5.69x throughput gap.

5. **Codec and metadata costs are real, smaller, and partly contractual.**
   mttp's strict request-head parse is 8.79% inclusive Ir, URL parsing 2.59%,
   response serialization (`head_bytes`) 1.90%, and header validation 1.30%.
   These overlap with allocation/destruction above. Headers normalize names;
   `of`, `add`, `remove`, `get_all`, and snapshot `iter` copy collections.
   Response headers are validated before serialization and again in
   `wire_fields`, which also removes CL/TE and inserts canonical framing.
   Request attributes copy an initially empty map three times for protocol,
   remote address and background scheduling; measured string-valued puts
   cost 0.28% inclusive, empty construction 0.15% (the function-valued put is
   another specialization). These are not enough to explain the gap alone.

   `ServerState::step` is **2.15% inclusive**: two Activity transitions/req
   update the persistent connection map and broadcast a condition. Ordinary
   requests call `stopping` at the loop boundary and before writing; there
   is **no periodic 250 ms poll** for this body (only marked long-lived
   streams poll). Date is cached per connection/second: `Session::date`
   totals **0.21% inclusive**, with 373 formatting calls in the deliberately
   slow 2,000-request Callgrind run. Core formats Date once at startup. Date
   caching could improve further, but is not the main cause. No access log
   runs per request: the default error callback does nothing and READY is
   printed once at startup.

## Scratch experiments and ranked candidates

The experiment copy was `/var/tmp/mttp-plan/scratch/v15/experiment`.
All other production sources and limits were unchanged. No experiment was
applied to this worktree. Estimates below are investigation priorities,
not promised gains; they overlap and must not be multiplied.

| Rank | Candidate | Evidence / expected gain | Correctness risk and relevant tests |
|---:|---|---|---|
| 1 | Keep Bytes/Empty bodies on their direct path while explicitly acknowledging response completion | Scratch added `if response.body is Bytes(_) { return response }` at the start of `lease`. Adjacent baseline 10,078.3 → 11,730.2 req/s, **+16.4%** (only +8.1% against the earlier baseline). Timer starts fall ≈5→3/req, coroutine creations ≈19→15, allocation calls ≈1,491→1,204. This isolates an avoidable cost but leaves most of the gap. | **High unless completion is preserved.** The scratch bypass loses the done notification and is not a valid fix. Preserve active status until final wire write, error and cancellation cleanup, HEAD/204/304, empty bodies and streams. `mttp/src/server/response_test.mbt`, `integration_test.mbt`, `shutdown_test.mbt`; `h1server/ownership_test.mbt`, `shutdown_test.mbt`. |
| 2 | Reduce per-I/O task/group creation while retaining a cancellable, joined owner for both directions and efficient deadline scopes | Nineteen coroutine creations and 1,491 allocations/req versus none per request and 287 in core. Largest remaining opportunity; a **20–50% throughput improvement is a hypothesis**, based on removing a material part of the 62.5% allocation/destruction work, not a measurement. | **High.** The child tasks exist because core handle close can detach an outstanding operation without waking its waiter. Preserve close wakeup, one reader, commit consumed bytes before cancellation, partial-write failure classification, external cancellation and virtual-clock behavior. `internal/socketconn/socket_wbtest.mbt`, `conn/bridge_wbtest.mbt`, `runtime/contract_test.mbt`, `runtime/virtual_clock_test.mbt`, `h1server/disconnect_test.mbt`, `deadlines_test.mbt`, `ownership_test.mbt`; backend tests also share this adapter. |
| 3 | Reuse a bounded receive buffer, or grow an initially small head buffer to the existing 64 KiB maximum | `memset` is 11.36% self Ir; eliminating all of it gives an **instruction-only upper bound of 1.13x**, before any allocator savings. Scratch 4 KiB-cap result is recorded below. Prefer reuse/adaptive sizing over globally reducing bulk-read size. | **Medium/high.** Keep the 64 KiB read-ahead bound, one read owner, read-after-close behavior, and no loss/aliasing of pipelined bytes at monitor handoff. A global 4 KiB cap can regress 1 MiB/TLS throughput. `socket_wbtest.mbt`, `h1server/body_test.mbt`, `exchange_test.mbt`, `limits_test.mbt`, `disconnect_test.mbt`; rerun both small and 1 MiB benchmark rows. |
| 4 | Coalesce a bounded small head + Bytes body into one write | Proven 2→1 socket writes, potentially one fewer write timer and two fewer socket tasks; **10–25% throughput is an unmeasured target**, not a syscall-time-derived prediction. Keep a size threshold and the 64 KiB write bound. | **Medium/high.** Preserve sent-before-failure semantics (never send a second status line), per-write deadline meaning, HEAD/204/304 framing, drain/shutdown and streaming first-pull error handling. `h1server/response.mbt`, `wire.mbt`; `deadlines_test.mbt`, `body_test.mbt`, `ownership_test.mbt`, `smuggling_test.mbt`, `mttp/src/server/response_test.mbt`. |
| 5 | Reduce internal header copies/repeated validation and construct attributes once; avoid redundant lifecycle transitions | Parser 8.79%, URL parse 2.59%, lifecycle 2.15% inclusive give leads. Expect **single-digit gains per narrow change**, unmeasured. Date-only work is below 0.3% Ir here and should come last. | **Medium/high for codecs, low/medium for internal construction.** Keep immutable snapshot semantics and typed key isolation. Never skip validation of CL/TE fields merely because framing replaces them. Preserve Host/absolute-target checks, duplicate CL and CL+TE rejection, bounds, and shutdown activity ordering. `headers_test.mbt`, `validation_test.mbt`, `h1/write_test.mbt`, `h1/head_test.mbt`, `h1server/smuggling_test.mbt`, `limits_test.mbt`, server shutdown tests. |

## Verification and evidence

The buffer-only experiment restored the original lease, then changed the
receive allocation's `max_len.min(65536)` to `max_len.min(4096)`. Callgrind
recorded 1,049,769,960 Ir for 2,001 responses including a check and startup,
about 524,623 Ir/response versus 590,124: **11.1% fewer instructions**.
`memset` dropped from 134,018,400 to 10,352,679 Ir (11.36% to 0.99% of total).
Task creations stayed at about 19/req and malloc calls at about 1,494/req:
buffer sizing removes zeroing, not the main object-count problem.
Its host throughput was 8,241.2 req/s between controls of 11,165.6 and
2,075.2 req/s. This establishes **no reliable throughput gain or regression**;
the 4 KiB cap is not recommended as a finished optimization. Both experiment
loads returned exactly the expected 15-byte body in the precheck and only
200s/no errors under oha. The lease experiment's separate Callgrind run had
2,001 responses, 30,184 task creations and 6,036 timer starts, supporting the
19→15 and 5→3 explanations independently of its noisy throughput result.
Its 1,011,738,154 Ir total is about 505,616 Ir/response, **14.3% fewer
instructions** than the original mttp interval, with startup included in
the experiment rather than subtracted.

`moon info` passed. `scripts/gates.sh manifest --update` passed with 182 rows
and left the manifest byte-for-byte unchanged. `scripts/gates.sh quick` passed
on all four targets (`test counts match scripts/test_manifest.tsv (182
package-target rows)`, `gates: OK`). `scripts/gates.sh static` passed, including
`runtime interfaces: OK (58 packages; no runtime types; every target agrees)`
and `ledger check: OK - every uncovered line is ledgered`.
`scripts/gates.sh full` also passed (`gates: OK`), including the gate
self-tests, `resolver gate: OK (4 modules; isolated registry; no workspace
overrides)`, and `workerd check: OK (wrangler 4.160.1, port 35835)`.
There were no gate failure lines to report. The full gate used scratch
`npm_config_cache` and `XDG_CACHE_HOME` in addition to the writable
toolchain/config locations. The disposable source, toolchain and cache copies
were removed after verification; raw measurements and logs remain.
Detailed raw oha JSON, strace summaries/full traces, Callgrind dumps/annotations,
Memcheck logs and gate logs are under `/var/tmp/mttp-plan/scratch/v15/`.
The primary inputs are `mttp-base1.json`, `core-base1.json`,
`mttp.callgrind.3` (reset interval), `core2.callgrind.1`,
`mttp-strace-summary.txt`, `core-strace-summary.txt`, `mttp-wire2.txt`,
`core-wire.txt`, `mttp.memcheck`, and `core.memcheck`. Scratch profiles are
`nolease.callgrind.1` and `buffer4k.callgrind.1`. The annotated text keeps
symbol names available after the disposable executable copies are removed.
Failed connection-refused exploratory runs (`core-callgrind.json`,
`mttp-wire.json`) and empty interrupted strace summaries were discarded from
analysis; only the successful replacements and 20,000-response summaries
support the figures above. Profiles are not committed as large binary files.

## V15a: direct Bytes/Empty responses

Starting from `a861fe6`, implement only candidate 1. The listener leaves
Bytes/Empty bodies on the engine's direct write path. Its private stream
wrapper now only makes stream cleanup idempotent; it no longer holds a done
callback, a sent flag, or special fixed-body/HEAD framing logic.
`h1server.serve_conn(on_response_complete~)` acknowledges a returned response
after its writes, body cleanup and unread-request drain, including failure
and cancellation. The listener still commits idle at the next-request
checkpoint, after the peer monitor has joined. Successful upgrades skip the
HTTP acknowledgement and retain admission through their callback.

Keep the observable `close_on_shutdown` behavior of formerly leased fixed
bodies: check before sending the body and after a nonempty Bytes body, never
cut a Bytes value in the middle of its bounded writes. An already-stopping
marked Bytes response keeps its declared length and closes short, just as
the old lease did. HEAD/204/304 and Empty framing, Date, abandonment, drain
and keep-alive decisions, the sent-before-write marker, and each 64 KiB
write's deadline stay in their existing engine paths. No buffer, socket-task,
header-copy or write-coalescing optimization is included.

### Instruction counts

Same native release build flags and the container/libc/Valgrind versions
above. Run each executable separately on port 39165, check the exact 15-byte
body, use `callgrind_control --zero`, send 2,000 requests with pinned oha
(`-n 2000 -c 32 --http-version 1.1 --no-tui --output-format json
--wait-ongoing-requests-after-deadline`), then request a dump before SIGTERM.
Both loads returned 2,000 HTTP 200s and an empty error distribution.
`callgrind_annotate` PROGRAM TOTALS from the reset intervals are:

| | Before | After | Change |
|---|---:|---:|---:|
| Total Ir / 2,000 responses | 1,182,893,835 | 1,024,669,270 | -13.38% |
| Ir / response | 591,447 | 512,335 | -13.38% |

Startup and the exact-body check are excluded on both sides. As in the
original report, these are user-space instruction counts, not CPU cycles.
The raw dumps are `before.callgrind.1` and `after.callgrind.1`, with
`before-callgrind-annotated.txt` and `after-callgrind-annotated.txt`, under
`/var/tmp/mttp-plan/scratch/v15a/`.

### Regression coverage

Five portable tests were added in `h1server/deadlines_test.mbt` and
`ownership_test.mbt`: a large Bytes write stalled after its head and first
64 KiB slice (timeout and cancellation); completion after the final Bytes
write or stream terminator; once-only completion for Empty/HEAD/204/304 and
pre-head failure; completion after unread-request draining with subsequent
reuse; and no HTTP completion for a successful upgrade.
Three real-TCP tests in `server/response_test.mbt` pin large Bytes shutdown
draining (including `close_on_shutdown`), a nonreading peer's Write timeout,
and cutting a marked Bytes response before its body when already stopping.
The initial versions of these TCP regressions also passed against the
unchanged baseline, pinning the behavior being preserved. The h1server count
is 99 on each of the four targets; the listener count is 28 on native and wasm.

The first static coverage run exposed timing-based synchronization in the
already-stopping TCP test. Its exact failure was:

```text
[gaato/mttp] test server/response_test.mbt:270 ("close_on_shutdown still cuts Bytes before its first write when already stopping") failed: src/server/response_test.mbt:292:7-292:54@gaato/mttp FAILED: `false` is not true
Total tests: 1485, passed: 1484, failed: 1.
error: instrumented native test run failed
FAIL: script scripts/coverage_report.mbtx
```

Replace the 1 ms sleep with an explicit handshake: after cancelling the
listener, wait for a previously accepted idle connection to close before
releasing the active handler. This proves the listener applied Stop before
the response is returned. The focused instrumented listener suite then
passed 28/28. No production code changed for this correction.

### Throughput measurement conditions

Run the complete `scripts/gates.sh bench` comparison three times before and
three times after, using the pinned toolchain, `MOON_CC=cc` and Docker.
Compare per-row medians rather than selecting a favorable run. Baseline
run 2's 1 MiB / 1-connection interval overlapped a focused native test build
from 12:37:11 to 12:37:14 JST; retain that observation in the three-run median.
Profiler-tool preparation also overlapped baseline run 1 and may affect its
control rows. The after runs are separate from correctness gates and tool
preparation. The host remains shared and has no CPU affinity, so wall-time
changes are observations;
the independent instruction counts above establish the reduction in work.

### Correctness gates

`moon info` passed. `scripts/gates.sh manifest --update` passed with 186 rows;
only h1server's 94→99 and the listener's 25→28 counts changed, in the original
row order. `scripts/gates.sh quick` passed on all four targets:
`test counts match scripts/test_manifest.tsv (186 package-target rows)`.
After correcting the test synchronization described above,
`scripts/gates.sh static` passed, including 1,485/1,485 instrumented tests,
`runtime interfaces: OK (60 packages; no runtime types; every target agrees)`
and `ledger check: OK - every uncovered line is ledgered`.
`scripts/gates.sh full` then passed with the corrected test on every target,
the gate self-tests, `resolver gate: OK (4 modules; isolated registry; no
workspace overrides)`, and `workerd check: OK (wrangler 4.160.1, port 35019)`.
Every final gate printed `gates: OK`; there were no remaining failure lines.
Logs are `info.log`, `manifest.log`, `quick.log`, `static.log` (the initial
test failure), `sync-coverage.log`, `static-retry.log` and `full.log` under
`/var/tmp/mttp-plan/scratch/v15a/`.

### Server medians: three complete runs per side

All six `scripts/gates.sh bench` runs passed the exact-body checks and
accepted only HTTP 200s without request errors. Each value below is the
median of its field in the three runs, rather than a field taken from one
selected run. Rates are requests/second; latency values are milliseconds.

| implementation | body | connections | before req/s | after req/s | change | before p50 | after p50 | before p99 | after p99 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| mttp | 15 B | 1 | 10,006.3 | 9,344.6 | -6.61% | 0.095 | 0.092 | 0.149 | 0.243 |
| mttp | 15 B | 32 | 10,619.5 | 12,104.3 | +13.98% | 2.973 | 2.638 | 3.407 | 3.107 |
| mttp | 1 MiB | 1 | 1,920.6 | 1,852.7 | -3.54% | 0.505 | 0.495 | 0.730 | 0.838 |
| mttp | 1 MiB | 32 | 1,812.1 | 1,705.0 | -5.91% | 17.519 | 18.413 | 19.811 | 23.103 |
| core/async/http | 15 B | 1 | 28,309.7 | 27,791.9 | -1.83% | 0.032 | 0.032 | 0.054 | 0.049 |
| core/async/http | 15 B | 32 | 60,003.1 | 60,303.2 | +0.50% | 0.501 | 0.486 | 0.732 | 0.816 |
| core/async/http | 1 MiB | 1 | 200.4 | 199.3 | -0.54% | 5.166 | 4.746 | 6.372 | 8.652 |
| core/async/http | 1 MiB | 32 | 178.5 | 148.7 | -16.70% | 175.782 | 209.390 | 250.992 | 310.269 |
| Go net/http | 15 B | 1 | 27,248.7 | 23,130.2 | -15.11% | 0.033 | 0.041 | 0.053 | 0.061 |
| Go net/http | 15 B | 32 | 183,154.2 | 133,821.5 | -26.94% | 0.100 | 0.129 | 1.041 | 1.427 |
| Go net/http | 1 MiB | 1 | 6,400.2 | 5,998.5 | -6.28% | 0.146 | 0.162 | 0.207 | 0.215 |
| Go net/http | 1 MiB | 32 | 6,090.3 | 5,983.3 | -1.76% | 5.121 | 5.212 | 10.713 | 11.139 |
| Node http | 15 B | 1 | 24,768.4 | 25,095.5 | +1.32% | 0.036 | 0.036 | 0.068 | 0.059 |
| Node http | 15 B | 32 | 40,950.1 | 40,454.5 | -1.21% | 0.736 | 0.769 | 1.559 | 1.568 |
| Node http | 1 MiB | 1 | 6,887.8 | 7,107.5 | +3.19% | 0.138 | 0.136 | 0.203 | 0.186 |
| Node http | 1 MiB | 32 | 6,939.9 | 7,209.1 | +3.88% | 4.443 | 4.295 | 8.554 | 8.248 |

The target 15 B / 32-connection case improves **13.98%** in the observed
median, with **13.38% fewer instructions**. Keep this change: it meets the
10% target on that case and simplifies fixed-body handling. The other mttp
medians are lower by 3.54–6.61%; this is not evidence of an improvement on
those rows. Their after-run ranges, especially after run 1's 1 MiB row,
and the changed comparison-server rates show substantial host variation.
No general throughput guarantee follows from these observations.

The mttp throughput observations, in execution order (not sorted), were:

| body | connections | before runs 1, 2, 3 | after runs 1, 2, 3 |
|---|---:|---|---|
| 15 B | 1 | 10,077.2; 9,881.5; 10,006.3 | 8,448.1; 9,636.4; 9,344.6 |
| 15 B | 32 | 10,989.5; 10,525.5; 10,619.5 | 9,945.3; 12,104.3; 12,142.7 |
| 1 MiB | 1 | 1,958.3; 1,828.0; 1,920.6 | 719.3; 1,852.7; 1,978.2 |
| 1 MiB | 32 | 1,868.2; 1,812.1; 1,740.1 | 1,299.7; 1,705.0; 1,910.5 |

For context, the host's `/proc/loadavg` was `9.73 9.44 8.98` at 13:30:56
JST during after run 2. This is an observation, not proof of the cause of
any particular low result. After run 1's 1 MiB / 1-connection result was
719.3 req/s; the same executable then gave 1,852.7 and 1,978.2 req/s.
The timing executable and the Callgrind after-copy have identical SHA-256
hashes (recorded in `executables.sha256`).

Raw complete comparisons are `before1.json` through `before3.json` and
`after1.json` through `after3.json` under
`/var/tmp/mttp-plan/scratch/v15a/`. Their matching `.log` files contain the
commands and `gates: OK`. The third complete after run was recorded with
`scripts/gates.sh bench --record` in `benchmarks/results/2026-11-16.json`;
`benchmarks/README.md` displays that run. These tables retain the median
comparison separately from that full-run snapshot.

The disposable writable toolchain, config/cache directories, profiler
container and executable copies were removed after verification. Raw
measurements, profiles, annotations and gate logs remain in the evidence
directory above.

## V15b: reusable receive storage

Starting from `9c35897`, change the private socket adapter first. Its receive
array is now lazy, starts at at most 4 KiB, and is retained on that connection.
A full read at the current target doubles the next target, capped at 64 KiB;
a caller's smaller max_len neither overreads nor triggers growth. Short
reads retain the current capacity. This avoids repeatedly zeroing 64 KiB
for a 129-byte request without imposing a permanent 4 KiB bulk-read cap.
There is no global pool. Close releases the connection's retained reference;
an in-flight child keeps its local array until joined cleanup. Each completed
read still copies its initialized prefix into independently owned pending Bytes in the
child, before waking its waiter, preserving cancellation handoff and preventing
later reads from mutating returned bytes. RESOURCE_BOUNDS records retained
capacity and the bounded old-plus-new allocation transient during growth.

The two new socket white-box tests drive growth through 4/8/16/32/64 KiB,
send more than the ceiling and check storage identity at the ceiling, release
on close, small max_len values, and immutable results across reuse. The
existing EOF/directional-bound test now expects the initial 4 KiB read;
the existing cancelled-waiter test continues to pin committed-byte handoff.

Measurement uses three complete `scripts/gates.sh bench` runs per stage,
without changing its duration, concurrency, exact-body checks or load images.
The receive-only stage is also the before measurement for write coalescing.
Raw JSON and command logs are under `/var/tmp/mttp-plan/scratch/v15b/`,
named `base{1,2,3}`, `receive{1,2,3}` and `coalesce{1,2,3}`. Each table uses
the median of each field independently. No benchmark snapshot is replaced.
The host is shared; `/proc/loadavg` read `10.46 8.46 7.12` at 14:15 JST.
The first base attempt timed out in the 1 MiB / 1-connection oha command
(`benchmark: TimeoutError`; `gates: FAILED (1)`), and is retained as
`base-attempt1.log` but excluded from medians. Two further attempts timed out
in Node's large/32 row and core's small/1 row, retained as
`base-attempt2.log` and `base-attempt3.log`. A Docker event showed the latter
oha container exit successfully after about 84 seconds, beyond the driver's
40-second command guard. Subsequent runs temporarily allow 190 seconds for
that command; oha still measures `-z 10s`, with the same completion-wait
option and validation. The first successful base run used the original
guard. Frozen, stage-specific executable copies let source checks proceed
without changing a running benchmark's code; command logs identify their
paths. These driver-only substitutions are restored before final gates.
Profiler installation overlapped
the first failed attempt. A focused baseline JS h1server test run overlapped the
control/client portion of successful base run 1, after its mttp server rows.

Callgrind uses the same native release executables, pinned Python container,
Debian Valgrind 3.19.0 and glibc 2.36 as V15a. For each stage, start the server
on port 39165, run the executable's exact-body check, reset counters with
`callgrind_control --zero`, send exactly 2,000 pinned-oha requests with 32
connections, then dump counters before terminating the server. Startup and
the precheck are excluded. These are user-space instructions, not CPU cycles;
unlike throughput they do not depend on host CPU scheduling. The baseline
reset interval (`base.callgrind.1`) is **1,024,027,395 Ir**, or **512,014 Ir
per response**. The baseline instruction load overlapped the failed bench
attempt and the beginning of its replacement; there were no competing
profiler loads.

Receive-only Callgrind (`receive.callgrind.1`) records **853,982,531 Ir**
for 2,000 HTTP 200s with no errors: **426,991 Ir/response**, **16.61% less**
than the same-session baseline. Reuse removes allocation work as well as
zeroing, so the saving exceeds the earlier memset-only estimate. Keep this
change. Its focused native and wasm socket suites both pass **12/12** with
`--deny-warn`.

### Receive storage: server medians, three runs per side

Rates are req/s, latency values are ms. `core` is core/async/http; `go` is
Go net/http. Each of the six complete runs passed its exact-body checks,
accepted only 200s and reported no request errors. The mttp small/32 median
improves **2.97%**, while the independent instruction count falls **16.61%**.
The Go control's small/32 median varies by -46.25%, reinforcing the shared
host caveat rather than supporting an instruction-to-throughput equivalence.

| implementation | body | connections | before req/s | after req/s | change % | before p50 | after p50 | before p99 | after p99 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| mttp | 15 B | 1 | 10025.1 | 10597.6 | 5.71 | 0.09 | 0.087 | 0.147 | 0.138 |
| mttp | 15 B | 32 | 12097.3 | 12456.1 | 2.97 | 2.59 | 2.565 | 4.128 | 3.031 |
| mttp | 1 MiB | 1 | 1891.4 | 1951.3 | 3.17 | 0.497 | 0.487 | 0.71 | 0.699 |
| mttp | 1 MiB | 32 | 1781 | 1870.7 | 5.04 | 17.657 | 17.054 | 23.793 | 19.698 |
| core | 15 B | 1 | 24071 | 26133.5 | 8.57 | 0.037 | 0.033 | 0.068 | 0.058 |
| core | 15 B | 32 | 57879.9 | 57522.4 | -0.62 | 0.548 | 0.553 | 0.753 | 0.795 |
| core | 1 MiB | 1 | 199.9 | 207.8 | 3.94 | 4.66 | 4.464 | 8.298 | 8.426 |
| core | 1 MiB | 32 | 182 | 164.5 | -9.64 | 173.675 | 189.426 | 210.284 | 488.001 |
| go | 15 B | 1 | 26043.7 | 24069.1 | -7.58 | 0.036 | 0.038 | 0.055 | 0.063 |
| go | 15 B | 32 | 154953.4 | 83283.9 | -46.25 | 0.112 | 0.181 | 1.189 | 3.255 |
| go | 1 MiB | 1 | 5713.3 | 4250.5 | -25.6 | 0.162 | 0.19 | 0.45 | 0.741 |
| go | 1 MiB | 32 | 5397.1 | 5780.6 | 7.11 | 5.73 | 5.406 | 13.295 | 12.347 |
| node | 15 B | 1 | 22766.4 | 21635.4 | -4.97 | 0.039 | 0.042 | 0.076 | 0.078 |
| node | 15 B | 32 | 38411.2 | 34282.5 | -10.75 | 0.762 | 0.883 | 1.782 | 2.039 |
| node | 1 MiB | 1 | 6523.9 | 6253 | -4.15 | 0.141 | 0.147 | 0.208 | 0.257 |
| node | 1 MiB | 32 | 6965.2 | 6244.3 | -10.35 | 4.448 | 4.964 | 8.549 | 9.71 |

## V15b: one bounded write for a small Bytes response

Apply this second, on top of reusable receive storage. A nonempty Bytes
body coalesces with its serialized head only if their combined size is at
most **4 KiB**. This one-page copy budget includes unusually large heads,
covers ordinary small replies, and never copies a large body to save a
write. The limit check subtracts only after bounding the body, so it cannot
overflow. Empty replies already need only one write and do not concatenate.
The existing `Wire::write` still owns the per-write deadline and 64 KiB
slicing; the combined write consumes one such budget. The sent marker is
set before either branch. Completion, unread-request drain, HEAD/204/304,
streaming first pulls and upgrades retain their existing owners. A marked
response already cut by shutdown cannot enter the combined branch; a sent
Bytes body keeps the existing post-write shutdown check.

Three new portable tests cover exactly 4 KiB and the next byte, empty/15 B/
4 KiB/64 KiB-plus bodies, a large head with a small body, and a blocked
combined write's success, timeout and external cancellation. They assert
one write for a bounded reply, separate bounded writes above it, exact
wire bytes, no premature or repeated completion, and no fallback status
line after a failed sent write. Existing bodiless completion tests also
explicitly reject the hidden body. Before implementation, the new combined
write and budget tests failed (`2 != 1`), while **100/102** h1server JS tests
passed. With the optimization the suite passes **102/102**, and the native
listener suite passes **28/28**, both with `--deny-warn`.

### Instructions: each change in order

| Stage | Ir / 2,000 responses | Ir / response | Change from preceding stage |
|---|---:|---:|---:|
| `9c35897` baseline | 1,024,027,395 | 512,014 | — |
| Reusable adaptive receive storage | 853,982,531 | 426,991 | -16.61% |
| Plus bounded write coalescing | 705,252,173 | 352,626 | -17.42% |

The combined reduction is **31.13%**. All three Callgrind loads returned
exactly 2,000 HTTP 200s with empty error distributions. Keep both changes:
they reduce actual work independently of the host's wall-time variation.
The second and third profiles are `receive.callgrind.1` and
`coalesce.callgrind.1`; each has an annotated text file, Valgrind log and
oha JSON beside it. `executables.sha256` identifies all three native release
copies. The coalescing profile overlapped the control portion of receive
bench run 1, after its mttp rows; the manifest refresh began after that
profile's oha load completed. Source verification and release builds also
overlapped the control/client portion of base run 3. Treat the comparison
server timings as controls on a shared host, not isolated causal estimates.

### Write coalescing: server medians, three runs per side

Same units and per-field medians as above. All three coalescing runs passed
their exact-body checks, accepted only 200s and reported no request errors.
The small/32 median improves **27.56%**, with **17.42% fewer instructions**
in the fixed-load profile. The 1 MiB/32 median decreases **8.80%**; this is
a measured limitation, not an improvement. Large bodies are outside the
coalescing branch, as the bounded-write regression confirms. Controls vary
substantially and unevenly (for example Go small/32 +98.01% and core small/32
-6.57%), so these timings alone cannot isolate that large-body change's cause.

| implementation | body | connections | before req/s | after req/s | change % | before p50 | after p50 | before p99 | after p99 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| mttp | 15 B | 1 | 10597.6 | 13413.6 | 26.57 | 0.087 | 0.069 | 0.138 | 0.109 |
| mttp | 15 B | 32 | 12456.1 | 15888.8 | 27.56 | 2.565 | 2.012 | 3.031 | 2.61 |
| mttp | 1 MiB | 1 | 1951.3 | 2008.4 | 2.92 | 0.487 | 0.49 | 0.699 | 0.683 |
| mttp | 1 MiB | 32 | 1870.7 | 1706.2 | -8.8 | 17.054 | 18.59 | 19.698 | 24.681 |
| core | 15 B | 1 | 26133.5 | 27786.9 | 6.33 | 0.033 | 0.032 | 0.058 | 0.055 |
| core | 15 B | 32 | 57522.4 | 53744.9 | -6.57 | 0.553 | 0.556 | 0.795 | 2.189 |
| core | 1 MiB | 1 | 207.8 | 200.1 | -3.69 | 4.464 | 4.532 | 8.426 | 8.341 |
| core | 1 MiB | 32 | 164.5 | 156.8 | -4.66 | 189.426 | 184.694 | 488.001 | 382.204 |
| go | 15 B | 1 | 24069.1 | 27408.4 | 13.87 | 0.038 | 0.034 | 0.063 | 0.051 |
| go | 15 B | 32 | 83283.9 | 164911.7 | 98.01 | 0.181 | 0.105 | 3.255 | 1.156 |
| go | 1 MiB | 1 | 4250.5 | 6202.6 | 45.93 | 0.19 | 0.156 | 0.741 | 0.214 |
| go | 1 MiB | 32 | 5780.6 | 6063.8 | 4.9 | 5.406 | 5.158 | 12.347 | 10.969 |
| node | 15 B | 1 | 21635.4 | 25496.9 | 17.85 | 0.042 | 0.036 | 0.078 | 0.056 |
| node | 15 B | 32 | 34282.5 | 39135.1 | 14.15 | 0.883 | 0.747 | 2.039 | 1.638 |
| node | 1 MiB | 1 | 6253 | 6979 | 11.61 | 0.147 | 0.137 | 0.257 | 0.19 |
| node | 1 MiB | 32 | 6244.3 | 6992.6 | 11.98 | 4.964 | 4.433 | 9.71 | 8.565 |

### Supplement: investigate the large/32 timing decrease

After the nine timing runs, profile the frozen receive-only and coalescing
executables for **200 requests each, 1 MiB, 32 connections**, under the same
Callgrind/container/libc setup. Check the exact large body, zero counters,
use pinned oha `-n 200 -c 32` with the same HTTP/completion options, and dump
before termination. Both loads return 200 HTTP 200s and no errors. Full
gate tests run concurrently; timing from these instrumented loads is not
treated as a throughput result.

| Large/32 stage | Ir / 200 responses | Ir / response |
|---|---:|---:|
| Receive-only | 759,332,103 | 3,796,661 |
| Plus write coalescing | 759,375,830 | 3,796,879 |

The difference is **+0.00576%**: no instruction increase commensurate with
the observed -8.80% timing median. This does not establish the cause of the
timing drop: Callgrind does not measure CPU cycles, kernel cost or scheduling.
Retain the negative timing observation as a limitation and keep the change
for its demonstrated small-response gains. Raw dumps and annotations are
`receive-large.callgrind.1`, `coalesce-large.callgrind.1` and the corresponding
`*-large-callgrind-annotated.txt`; their oha JSON and Valgrind logs remain
beside them. No production change followed this supplemental measurement.

### Logical change groups for handoff

* Receive storage: `mttp/src/internal/socketconn/socket.mbt`,
  `socket_wbtest.mbt` in that directory, and `mttp/CHANGELOG.md`.
* Write coalescing: `mttp_core/src/h1server/response.mbt`, `body_test.mbt`,
  `deadlines_test.mbt`, `ownership_test.mbt`, and `mttp_core/CHANGELOG.md`.
* Shared files have independent hunks: RESOURCE_BOUNDS' receive-storage row
  and directional-test reference belong to the first change, and its
  coalesced-storage row to the second;
  `scripts/test_manifest.tsv`'s socketconn counts belong to the first and
  h1server counts to the second. This profile's receive section and first
  comparison describe the first change; its coalescing section and second
  comparison describe the second. No public interfaces or package manifests
  change, and no commits are made in this worktree.

The excluded benchmark attempts report these failure lines (the two later
attempts both targeted `base2.json`):

```text
benchmark: TimeoutError
FAIL: script benchmarks/run.mbtx -- --output /var/tmp/mttp-plan/scratch/v15b/base1.json
gates: FAILED (1)
benchmark: TimeoutError
FAIL: script benchmarks/run.mbtx -- --output /var/tmp/mttp-plan/scratch/v15b/base2.json
gates: FAILED (1)
```

During receive run 2, at 14:47 JST, `/proc/loadavg` was `10.43 8.80 7.93`.
The all-target manifest refresh overlapped that run, including its mttp
rows. Those observations remain in the median; no favorable runs are
selected or substituted on account of host load.

`moon info` and `scripts/gates.sh manifest --update` pass. The manifest
retains all 186 rows in their original order, changing only socketconn's
10→12 (native/wasm) and h1server's 99→102 (all four targets).
`scripts/gates.sh quick` passes on all four targets with
`test counts match scripts/test_manifest.tsv (186 package-target rows)`
and `gates: OK`. Quick ran from approximately 14:51 to 15:01 JST,
overlapping receive run 3's control/client rows and coalesce run 1, plus the
beginning of coalesce run 2. No correctness failure occurred in these gates.

After coalesce run 3 had started and its mttp rows had completed,
`benchmarks/run.mbtx` was restored byte-for-byte to its original contents.
Its diff is empty. Static verification then passes: `runtime interfaces: OK (60
packages; no runtime types; every target agrees)`, **1,490/1,490**
instrumented native tests, `ledger check: OK - every uncovered line is
ledgered`, and `gates: OK`. Static and the subsequent full gate overlap
only the control/client portion of the final benchmark run, whose already
running script uses its frozen coalescing executable. Logs are `info.log`,
`manifest.log`, `quick.log`, `static.log` and `full.log` in the evidence
directory.

`scripts/gates.sh full` also passes: the all-target tests, repeated static
checks and coverage ledger, gate self-tests,
`resolver gate: OK (4 modules; isolated registry; no workspace overrides)`,
`workerd check: OK (wrangler 4.160.1, port 35603)`, and final `gates: OK`.
There are no remaining correctness gate failures. The disposable profiler
containers, executable copies, writable toolchain and config/cache copies
are removed after verification; raw JSON, profiles, annotations and gate
logs remain in `/var/tmp/mttp-plan/scratch/v15b/`.

## V15c: fewer directional tasks and header copies

Starting from `b1ca92b`, implement the remaining task-count and header-copy
candidates without changing public interfaces, deadlines or framing policy.

### Structured owners

`SocketConn` now performs the read or bounded write loop in the task group's
own callback, already a cancellable child. The former additional `spawn`
and `Task::wait` disappear from every normal I/O. Close first marks the
connection closed, then schedules at most one cancellation child for each
active direction. That child calls `return_immediately` on its direction's
group, waking the I/O owner even if core's handle close detached the pending
operation. The caller still joins the owner and all cleanup before returning.
The queued-owner closed check and checks between write slices prevent a
write from starting after close. A cancelled read waiter still leaves consumed
bytes committed in independently owned pending storage.

`RuntimeCoordination.supervise` similarly runs primary in the existing group
callback and spawns only the monitor. A monitor failure records the first
error and ends the group; a normal monitor completion leaves primary running.
Primary completion is recorded before monitor cleanup, and its delivered
result cannot be replaced by a late monitor failure. Caller cancellation
that races a synchronously completed owner is explicitly delivered after
joining, for sockets and supervision alike.

These are structural counts on the pinned core/async implementation:

| Scope | Before | After |
|---|---:|---:|
| Normal socket read or write | 2 tasks | 1 task |
| Supervision | 3 tasks | 2 tasks |
| Additional work on explicit close | cancel existing I/O child | at most 1 cancellation child per active direction |

There is still a task group per operation. The timer/virtual-clock scopes,
64 KiB directional bounds, partial-write error classification and TCP/TLS
failure translation remain in place. These counts do not establish a
throughput improvement. The Callgrind comparison below measures the
instruction reduction on the 15 B / 32-connection case; other body sizes
and wall-clock throughput were not measured in V15c.

### Header construction

`Headers::of` maps the caller's view directly into one owned array instead
of copying and then mapping. `iter` retains the existing array: every
constructor owns its array, no header method mutates it, and no method
exposes it. It therefore remains an immutable snapshot without an extra
array copy. `get_all` and materialized iteration results remain independently
mutable by their caller.

The HTTP/1 writer validates all original fields, filters CL/TE into one
private array and appends canonical framing in place. Previously, two
`remove` operations and a framing `add` each constructed a new collection,
followed by an iteration snapshot copy. UntilClose still replaces Connection
at its first original position and removes duplicates. Validation of replaced
fields, Latin-1 serialization, field order and duplicate field values remain
unchanged. The engine's earlier response validation is retained so invalid
headers are refused before a stream producer is pulled. Attribute construction
and lifecycle transitions are unchanged.

### Callgrind measurement — 2026-11-17

Measure the existing `benchmarks/transport/main.mbt` server unchanged, using
the method from V15a: native release, `MOON_CC=cc`, moon 0.1.20261104 / moonc
0.10.20+65efd5b93. Extract `b1ca92b` with `git archive` into
`/var/tmp/mttp-plan/scratch/v15c/before` and build it there; build the combined
after executable in `/var/tmp/mttp-plan/wt-v15c`, without replacing that
worktree's sources. The two other scratch copies start from the same archive:

* `tasks-only` replaces only `mttp/src/internal/socketconn/socket.mbt` and
  `mttp/src/runtime/coordination.mbt` with the worktree versions.
* `headers-only` replaces only `mttp_core/src/headers.mbt` and
  `mttp_core/src/h1/write.mbt` with the worktree versions.

Build each with `moon run benchmarks/transport --target native --release --
build`; all four builds pass. Run the resulting executables separately in a
disposable container based on the same pinned Python image as earlier rounds,
with Valgrind **1:3.19.0-1** and libc6 **2.36-9+deb12u14**. Install nothing on
the host. All builds finish before profiling begins.

For each interval, start a fresh server on `127.0.0.1:39165` under
`valgrind --tool=callgrind`, pass its executable's exact-body
`check http://127.0.0.1:39165/small small`, reset with
`callgrind_control --zero PID`, then run the pinned oha image from the method
section with `-n 2000 -c 32 --http-version 1.1 --no-tui --output-format json
--wait-ongoing-requests-after-deadline`. Request a dump with
`callgrind_control --dump PID` after oha exits, before sending SIGTERM.
Use the reset interval's `.callgrind.1` PROGRAM TOTALS from
`callgrind_annotate`; startup and the exact-body check are excluded, while
the load's connection establishment/cleanup is included, as in V15a.

Run in order **before, tasks-only, headers-only, after**, then repeat with
fresh server processes in reverse order **after, headers-only, tasks-only,
before**. Retain both runs rather than selecting the lower count. Every
exact-body check passes (15 bytes); all eight loads report exactly 2,000 HTTP
200 responses, `successRate: 1.0`, and an empty error distribution.

| Variant | Run 1 total Ir / 2,000 | Run 2 total Ir / 2,000 | Mean Ir / response | Change vs before mean |
|---|---:|---:|---:|---:|
| Before (`b1ca92b`) | 714,323,143 | 715,376,042 | 357,424.8 | — |
| Task reduction only | 627,227,532 | 627,237,967 | 313,616.4 | -12.26% |
| Header copies only | 704,206,798 | 703,385,719 | 351,898.1 | -1.55% |
| After (both) | 616,929,891 | 618,118,082 | 308,762.0 | **-13.61%** |

Keep **both** changes: each standalone variant reduces instructions in both
passes, and its two-run range is below the baseline range. Adding header
changes to task reduction lowers mean instructions a further **1.55%**.
No change needs a code-simplification exception to the retention rule.
These are user-space instruction counts, not CPU cycles or a throughput
claim. Skip duration-based/wall-clock benchmarks as requested.

Raw evidence remains under `/var/tmp/mttp-plan/scratch/v15c/`: the prefixes
`before`, `tasks-only`, `headers-only`, `after` and their `-repeat` variants
each have `.callgrind.1`, `-callgrind-annotated.txt`, `-oha.json`, `-check.log`,
`-zero.log`, `-dump.log` and `-valgrind.log`. Build logs,
`executable-sha256.txt` and `profile-environment.txt` identify the four builds
and tool versions. The disposable source copies, toolchain/config copies,
executable copies and profiler container were removed after measurement;
the raw profiles and logs remain readable by the workspace owner.

### Regression coverage and handoff

Five socket regressions cover close of both blocked directions, close after
the first 64 KiB write slice, caller cancellation at the final write and close
before a directional owner starts, plus cancellation whose I/O cleanup raises
an ordinary error. Existing cancelled-read handoff, storage
reuse, EOF, error mapping, TLS and bridge tests also run. Two runtime tests
cover synchronous primary outcomes versus a late monitor failure and caller
cancellation racing primary completion; the shared coordination contract
continues to cover nested cancellation, protection and joined cleanup.
Header tests retain a partially consumed iterator while mutating input and
derived results and making reentrant visits; writer tests pin original-header
isolation, Connection ordering and validation of all replaced fields.

Logical change groups for review are the socket adapter plus runtime
coordination and their tests (`mttp`), and Headers plus HTTP/1 serialization
and their tests (`mttp_core`). Their changelog, resource/coverage-ledger and
manifest hunks follow those groups. No commits are made in this worktree.

The first socket implementation exposed a real cancellation regression:

```text
[gaato/mttp] test internal/socketconn/socket_wbtest.mbt:89 ("cancelled read waiter retains bytes committed by its completed child") failed: src/internal/socketconn/socket_wbtest.mbt:99:7-99:38@gaato/mttp FAILED: cancelled read returned
```

The owner had committed the bytes, but completing the group before its
cancelled caller resumed left the signal pending. The post-join cancellation
checkpoint fixes this; the final read/write race regressions explicitly pin
both the signal and cleanup. The error path also delivers pending caller
cancellation before translating an error raised by I/O cleanup.

Final focused checks use moon 0.1.20261104 / moonc 0.10.20+65efd5b93,
`MOON_CC=cc`, a writable toolchain and XDG config under
`/var/tmp/mttp-plan/scratch/v15c/`. `moon check --deny-warn` and `moon info`
pass; generated `.mbti` files are unchanged. The four changed packages have
83 tests in the vocabulary package, 53 in h1, 28 in runtime and 17 in
socketconn. All pass on their supported targets: the first two on all four,
runtime on native/wasm/js and socketconn on native/wasm. The focused native
instrumented run passes 181/181 tests. The changed Headers and writer sources
are fully covered; socket's two unexecuted TLS IncompleteClose lines and
coordination's five defensive error-mapping lines are explicitly ledgered.
The socket ledger budget shrinks from three to two.

Repeated development coverage runs initially mixed stale counters and failed
with this tooling diagnostic:

```text
error: counter length mismatch for 'gaato/mttp/runtime$coordination': expected 31, got 29; remove stale coverage outputs
```

The final report uses the fresh `_build/v15c-coverage` run's trace maps and
counter files explicitly; its four `coverage-*-final.txt` reports succeed.
Focused check/test, formatting, info, coverage and manifest logs remain in
the scratch directory. No quick/static/full, interop or workerd run is made
here, per the shared-host task rules; the coordinator owns those stacked
checks. The subsequent Callgrind-only measurement above leaves implementation
and test sources unchanged, so those correctness results still apply.

`scripts/gates.sh manifest --update` passes with `gates: OK` and
`scripts/test_manifest.tsv: OK (211 rows)`. It preserves row order and changes
only the thirteen rows for the four changed packages:

| Package | Before | After | Targets tested |
|---|---:|---:|---|
| `gaato/mttp_core` | 82 | 83 | wasm-gc, wasm, js, native |
| `gaato/mttp_core/h1` | 52 | 53 | wasm-gc, wasm, js, native |
| `gaato/mttp/runtime` | 26 | 28 | wasm, js, native |
| `gaato/mttp/internal/socketconn` | 12 | 17 | wasm, native |

The changed packages total 136 tests on wasm-gc, 181 on wasm, 164 on js and
181 on native. Unsupported targets are not advertised for the runtime or
socket adapter. The manifest run also verifies final-code native conn
(11 tests), server (28), backend (25) and portable h1server (103 per target);
there are no remaining failing test lines. The writable toolchain and config
copies are removed after verification; logs and coverage reports remain in
`/var/tmp/mttp-plan/scratch/v15c/`.

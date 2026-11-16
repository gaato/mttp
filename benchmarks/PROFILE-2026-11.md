# Small-response server profile — 2026-11-16

Investigation of `8e6715c`, native release, `MOON_CC=cc`. No production code,
API, dependency, or test changes. The two experiments below ran in a disposable
source copy, not in this worktree.

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

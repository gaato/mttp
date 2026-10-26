# Pure decisions and portable HTTP/1

This refactor builds on `81adeb55d3270bb372946b8aa3c2c882604265de`, before
the first registry release. It preserves the existing socket facade defaults
while making its protocol engine usable through public connection ports.
The local implementation branch is `refactor/portable-transport`.

## Boundaries

| Layer | Owns | Examples |
| --- | --- | --- |
| Pure decisions | Immutable snapshots, persistent collections, returned effect descriptions | Retry/redirect plans; admission counts and queued IDs; idle-pool metadata; peer EOF/failure; listener shutdown |
| Local parsing and orchestration | One reader's mutable buffers/cursors; interpretation of decisions against injected ports | Existing h1 decoders, request/response bodies, portable client/server engines |
| Runtime adapters | TCP/TLS, time, scheduling, resource handles, wait/wake/close/cancel | TcpDialer, RuntimeCoordination, ClockTimer, listener |

`mttp-net/internal/control` contains no sockets, tasks, waiters, callbacks or
async functions. Each transition returns a new state, leaving old states
usable. Adapters retain a separate ID-to-resource table and commit transitions
before interpreting actions. Local temporary builders do not escape into
these states. Persistent HashMap/Vector updates avoid copying a whole pool
for every event.

The HTTP/1 engines are portable orchestration, not pure functions: they call
Conn, Dialer, Clock, Timer and Coordination. Parsers still mutate private
buffers. Making every input byte allocate a persistent buffer would increase
cost without strengthening the external ownership contract.

## Public extension points

- `gaato/mttp/conn`: Conn, Dialer, Signal, Coordination. Their lifecycle,
  error and cancellation rules are in [CONTRACT.md](../CONTRACT.md).
- `gaato/mttp-net/h1/client.H1Backend`: explicit dialer, clock, timer and
  coordination; all four targets. Proxy environment lookup is captured at
  construction through an optional injected callback.
- `gaato/mttp-net/h1/server.serve_conn`: owns an accepted connection, uses the
  same server engine as the listener, and closes it on every exit. A supplied
  background scheduler owns detached work; without one, no background
  attribute is advertised.
- `gaato/mttp-net/conn.TcpDialer`: native/Wasm TCP and verified TLS. TLS
  upgrade success transfers ownership; failure leaves cleanup with the caller.
- `gaato/mttp/testing/conn`: paired SimConn endpoints with configurable
  fragmentation and separate write-half shutdown, ScriptedConn fault events,
  ScriptedDialer and Driver-based coordination.

Runtime-specific accepted-socket conversion stays internal. Public signatures
contain no moonbitlang/async implementation types. The ordinary quick client
and AsyncBackend callers retain their existing construction pattern.

## Snapshot API migration

RetryContext now stores RequestHead and explicit idempotency/replayability.
Use `RetryContext::capture(request)` at a live-request boundary, or build a
pure context with `RetryContext::new(request.head(), idempotent~, replayable~)`.
RetryRule::decide takes the same explicit facts. Redirect planning similarly
returns a new head and a body-drop decision; body reuse/closure occurs outside
the planner. Capturing availability does not authorize automatic retries of a
stream: the Client still requires a body factory.

Server configuration types moved to `gaato/mttp-net/h1`; the runtime server
re-exports them. Constructor references use the type namespace, for example
`@server.ServerConfigError::InvalidMaxConnections`.

The isolated SDK and Discord migration workspaces contain follow-up changes
for these APIs. Requesto's PR contains deprecation documentation and no mttp
retry calls; the CLI uses the unchanged socket facade.

## Validation and performance

| Final local check | Result |
| --- | --- |
| Core/conformance test manifest | All packages pass on all four targets; equal-count rules pass |
| Portable client / server / pure control | 5 / 6 / 6 tests per target |
| Socket backend / listener | 53 / 31 tests on native and Wasm |
| Shared deterministic connection tests | 5 per target, including faulty-port negative cases |
| SDK/Discord/CLI affected consumer suites | 426 native and 400 JS tests pass; combined graph checks on all supported targets |
| Packaged migration graph | Isolated package creation and registry resolution pass |
| Chromium | 5 browser checks pass |
| Native line coverage | 6,353 / 6,412 (99.1%); closed ledger passes |

These are local results; no new CI run is implied before a push.

Plain Driver tests execute on native, JS, Wasm and Wasm-GC. They exercise
typed Endpoint → Router → client/server round trips at 1/17/65536-byte
fragmentation, framing rejection, body/head bounds, virtual deadlines,
cancelled admission, CONNECT/TLS event order, half-close, peer failure and
cleanup. Persistent-state tests retain earlier snapshots and check admission
bounds through 1,000 event transitions. Native/Wasm tests additionally retain
the real socket, verified/nested TLS and listener suites.

`scripts/architecture_gate.mbtx` rejects host imports in portable code,
effects or mutable fields in control states, and skipped-style async tests in
portable packages. `runtime_gates.mbtx` compares public interfaces, checks for
runtime type leaks and enforces per-target test counts. Coverage gaps remain
explicit in [TEST_COVERAGE.md](../TEST_COVERAGE.md): pure shutdown event orders
are tested, while several physical listener handoffs remain unforced. Abrupt
post-handshake TLS I/O failures also remain separate from the tested closed
connection and handshake failure cases.

Two reproducible workloads are retained:

- `moon run --release --target native scripts/state_copy_bench.mbtx` compares
  mutable state, whole-state copies and persistent state; it checks result
  equality before timing. For a 256-entry pool, the local median update was
  0.053 µs mutable, 1.455 µs full copy and 0.313 µs persistent. Locally mutable
  byte assembly remained faster than either immutable strategy.
- `moon run benchmarks/transport --release --target native` performs 32 warmup
  requests and three 500-request samples over one reused real TCP connection.
  The exact same source runs against the baseline and candidate. One local
  median was 55.1 → 57.4 µs/request for a single-write response and
  296.8 → 299.9 µs for one-byte writes. These small-response measurements are
  local observations, not a production capacity claim or a statistical bound.
  Empty uploads avoid concurrent upload tasks after their head write; streamed
  uploads retain the full early-response and producer-error handling.

The refactor does not validate remote cloud deployments or replace the
existing runtime. Release and remote GitHub operations remain separate work.

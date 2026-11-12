# Contracts

What code on either side of the `gaato/mttp_core` traits may rely on, and what the
sans-IO parsers guarantee. A backend, a runtime adapter, a test double or a
wrapper that keeps these rules can be used with every engine and client in the
family; a consumer written against them needs nothing more.

The traits live in two packages of `gaato/mttp_core`: the root (`Backend`,
`BodyStream`, `SendOptions`) and `rt` (Clock, Timer, Gate, Conn, Dialer,
Signal, Coordination). The doubles are in `gaato/mttp_core/sim`, the deterministic
scheduler in `gaato/mttp_core/driver`, and the runtime implementations in
`gaato/mttp_async`. The policy rules at the end (client attempts) belong to
`gaato/mttp_core/client`.

Shared checks: `@sim.check_conn`, `check_coordination_contract`,
`check_body_stream_contract` and `check_backend_contract` run against the sim
doubles and against mttp_async's adapters. Transport-specific rules (wire
framing, socket deadlines, TLS) are checked by each implementation's own
suites. For the implementations in this repository,
[TEST_COVERAGE.md](TEST_COVERAGE.md) names the tests behind each rule and
[RESOURCE_BOUNDS.md](RESOURCE_BOUNDS.md) the tests behind each bound.

## Clock

`sleep(Int) async -> Unit noraise`; `now_unix_ms() -> Int64`.

1. Nonpositive sleeps do not advance time. Cancellation propagates through
   the scheduler, never as an ordinary error (see Driver and cancellation).
2. `@sim.SimClock` shares its Driver's time; overlapping sleeps advance to the
   latest deadline, not the sum of durations.
3. `@sim.FakeClock` is explicitly a sequential accumulator: positive sleeps add
   their duration immediately. `advance` may adjust its wall time backward.
   Consumers needing concurrent timing use `SimClock`.

## Timer

`within(Int, async () -> Unit noraise) async -> Bool noraise`.

1. A nonpositive duration returns false without invoking the callback.
2. Successful callback completion returns true and disarms the deadline.
3. Expiry cancels the callback and returns false after it unwinds.
4. Caller cancellation cancels its child and disarms its deadline. Consumers
   must cooperate with cancellation; a synchronous infinite loop cannot be
   preempted by a cooperative scheduler.

## Gate

`acquire() async -> Unit noraise`; `release() -> Unit`.

1. Successful acquire owns one slot; consumers release it using `defer`.
2. Queued callers receive slots in FIFO order. A queued caller cancelled
   before handoff removes itself without consuming a slot.
3. A caller cancelled after handoff still receives its slot and may install
   cleanup before cancellation is delivered at its next suspension.
4. Extra releases are capped at capacity. Negative capacity is zero.

## BodyStream

`read_some() async -> Bytes? raise TransportError`; `close() -> Unit`.

1. Chunks are nonempty. EOF is permanent; reads after close return EOF.
2. Close is idempotent. The consumer closes on success, error and cancellation.
3. `StreamBody::take` grants one reader; copies of the containing body share
   acquisition state. A second take fails with `Unreplayable` in phase Pool.
4. A declared negative length is invalid before any read. A taken stream
   refuses a crossing chunk or premature EOF, closes its source, and does
   not expose bytes beyond the declared length.
5. `read_bounded` closes on every exit, rejects empty chunks, and refuses the
   first chunk that would exceed the limit using overflow-safe arithmetic.
6. Concurrent reads on the same stream are outside this contract.

## Connections and coordination

Conn reads return nonempty chunks of at most `max_len`; EOF permanently ends
only the read half. Writes consume all supplied bytes. One reader and one
writer may run concurrently. Close is idempotent and wakes pending operations;
a write after close raises TransportError. Cancellation finishes an
operation's cleanup before another operation in that direction begins.

`rt.Conn` has no write-half shutdown, because core/async offers none for
sockets or TLS. `@sim.SimConn::shutdown_write` exists only to test how peers
react to a half-closed stream.

A successful Dialer TLS upgrade owns its input connection. A failed upgrade
leaves that connection owned by the caller, which closes it. The runtime
`TcpDialer` verifies certificates according to its root-package
`gaato/mttp_async.Trust` value (`System`
by default; `Insecure` disables verification; `PemFile` trusts only the
certificates in the supplied PEM file, replacing system roots), and it
can upgrade any `&Conn`, including a CONNECT tunnel. `ScriptedDialer` records
upgrades without performing cryptography.

Signal is a sticky one-shot notification. Coordination runs primary and
monitor as structured children: monitor completion permits primary to
continue, monitor failure cancels primary, primary completion cancels monitor,
and every exit joins cleanup. The first delivered outcome wins. Parent
cancellation propagates after both children finish cleanup. The shared
coordination suite runs against `RuntimeCoordination` and `SimCoordination`.

## Backend

`send(Request, SendOptions) async -> Response raise TransportError`;
`close() -> Unit`.

1. **Validation first.** An invalid URL, header, method or body framing is
   refused before any I/O with `TransportError(kind=Invalid, phase=Pool, ..)`,
   which is unsent.
2. **Phases are honest.** Every failure carries the phase in which it
   happened. A failure reported in Pool or Dial means no request byte reached
   the peer; `is_unsent` relies on this.
3. **Request bodies.** The backend takes a stream body at most once and closes
   it on success, failure and cancellation. It performs the stream's first
   read before writing the request head, so a failing stream or one falsely
   declared empty sends nothing.
4. **Response ownership.** A returned Response's body belongs to the caller,
   who reads it to EOF or closes it. Closing early releases the connection;
   whether it may be pooled again is the engine's decision, never the
   caller's.
5. **Raw bytes.** A backend moves bytes. It does not follow redirects, retry,
   store cookies or undo content codings; wrappers that do so say so in their
   name and documentation (FollowRedirects, Cookies, Decompress). JS fetch is
   the per-target exception: it always negotiates and decodes codings, buffers
   request bodies, and is called with manual redirects.
6. **Close.** `close` is idempotent. Afterwards, new sends fail with
   `TransportError(kind=Closed, phase=Pool, ..)` without I/O; in-flight exchanges may fail
   with `Closed`, and their bodies remain closable.
7. **Cancellation.** Cancelling a send unwinds it, closes the resources it
   owns, and propagates the cancellation unchanged; it is never converted
   into a TransportError.
8. **Wrappers** keep rules 1–7 and pass SendOptions through unchanged unless
   they document otherwise.
9. **Unknown timings.** `BodyTiming` is `#non_exhaustive`. A backend that
   meets a variant it does not implement refuses the send before any I/O with
   `TransportError(kind=Invalid, phase=Pool, ..)`, as in rule 1, rather than
   guessing its meaning.

A backend written outside this repository, for example over another HTTP
engine, passes `@sim.check_backend_contract(make_backend)` from
`gaato/mttp_core/sim`, which exercises these rules (including rule 6's phase) on
the target it runs on.

`mttp_async/backend.AsyncBackend::new` accepts optional `rt.Clock` and
`rt.Timer` ports on every target. The defaults are `AsyncClock` and
`ClockTimer` on the chosen clock. Socket pool idle expiry uses that clock,
and phase deadlines use that timer. JS fetch uses them for upload, head and
body deadlines; its host-owned connection pool and wire phase timeouts remain
outside these ports.

## SendOptions and BodyTiming

`SendOptions { timeout_ms : Int?, body : BodyTiming }`.

1. `timeout_ms = None` means no attempt deadline at this layer. A
   nonpositive value fails the send at once with `Timeout(ms)`; the mttp
   Client never passes one.
2. `Exchange(max_bytes~)`: the caller reads the whole body inside the
   attempt. `timeout_ms` covers the head **and** the whole body. At most
   `max_bytes` body bytes arrive on the wire (after transfer framing, before
   any content decoding); the read that would cross the limit raises
   `TooLarge(limit)` in phase Body and the connection is discarded. A negative
   `max_bytes` is Invalid before I/O; zero admits only empty bodies. An
   engine-level ceiling (`ClientConfig.max_body_bytes`) applies as the minimum
   of the two.
3. `Stream(idle_ms~)`: the caller streams. `timeout_ms` ends when the head
   arrives; each later read waits at most `idle_ms` (`None`: no idle limit)
   and fails with `Timeout` in phase Body. The per-request length is not
   bounded at this layer; the reader bounds decoded bytes. The engine-level
   ceiling (`ClientConfig.max_body_bytes`) still bounds wire bytes, so coded
   bodies that decode to nothing (empty stored blocks, skippable frames,
   metadata blocks) cannot stream without end.
4. Decoded-byte limits are not a Backend concern. `Decompress` passes
   SendOptions through unchanged, so the engine bounds wire bytes, and the
   mttp Client's readers bound decoded bytes.

JS fetch is the per-target exception: only host-decoded body bytes are
visible, so both byte limits count those bytes. It cannot enforce a bound
on compressed wire bytes.

## Driver and cancellation

`gaato/mttp_core/driver` runs async code without a runtime, on virtual time, on
all four targets. Its cancellation semantics match core/async's:

1. **Cancellation is a signal, not an `Error`.** It is delivered by the
   scheduler, passes through `noraise` functions, and is not seen by `catch`
   clauses, so code cannot swallow it by catching everything. Code observes it
   only through unwinding (`defer`), `Task::is_cancel_requested` /
   `is_cancelled`, or `Resume::Cancelled` from `park_check_cancel`.
2. `Task::cancel` requests cancellation; it is delivered at the task's next
   suspension point (`park`, `sleep`, `pause`). A task that never suspends is
   never interrupted.
3. Unwinding runs every pending `defer`. Cleanup that must finish runs in a
   `nocancel` section (`cancel_and_join`, `park_check_cancel`); a deadline
   requests cancellation and may be followed by the required cleanup time.
4. `run_sync(f)` and `Driver::run(f)` return `f`'s value when the main task
   completes. A cancelled main task raises `DriverError(MainCancelled)`. A
   main task waiting on nothing that can happen raises `Suspended` or
   `Deadlock`. Exceeding `max_steps` (task steps or timer callbacks) raises
   `NoQuiescence` after cancelling and unwinding live tasks.
5. When `run` ends, live tasks are cancelled and unwound for at most
   `max_unwind_rounds` rounds; survivors raise `UnwindIncomplete(live~)`.
6. A spawned task that raises fails the run with `TaskFailed(label~, cause~)`
   unless spawned with `allow_failure=true`. The cause keeps its identity.
7. With `auto_advance`, virtual time moves only when no task is ready, and
   only forward, to the next armed timer.
8. **Runtime parity.** mttp_async's `ClockTimer`, `SemaphoreGate` and
   `RuntimeCoordination` satisfy the Timer, Gate and Coordination rules above
   with the same contract tests as the sim doubles, including the
   cancellation cases.

## Client attempts (gaato/mttp_core/client)

1. Retrying is opt-in. RetryPolicy is pure data. An optional typed decision
   function sees a Buffered reply, a StreamReady head or a TransportFailure,
   plus the policy's default decision. A streaming callback starts only after
   the attempt's release and observation; its result or exception is never
   retried.
2. Every acquire that returns has exactly one release, with that acquire's
   Admission. Cancelled admission waits have none. Release uses the received
   head even when reading fails. Each retry has its own Admission. Return
   tokens only to their issuing limiter; a second release of the same token
   is ignored, including after a failed release attempt.
3. Body factories run only after admission and a deadline check. Without a
   factory, stream requests cannot retry, regardless of the decision function.
4. A release failure after an exchange produced a value reaches the caller and
   closes the held body, including when that value is `Err`. It does not
   replace an already raised error or cancellation. Observers run once after
   release is attempted, with the actual HTTP status and response head.
5. A configured total deadline requires a Timer before admission or body
   preparation. It covers admission, attempts, retry waits and the streaming
   consumer. Expiry requests cancellation; necessary cleanup completes or
   compensates during unwind, so cleanup may finish after the deadline.
6. Built-in readers return `Result` values for status and decoding failures.
   `ResponseFailure` retains the real head and at most 1 MiB of diagnostic
   body. TransportError, cancellation and unknown user exceptions remain
   effects.
7. RequestPlan and ResponsePlan carry a Buffered or Streaming mode; the
   Client maps them to `Exchange` and `Stream`. `from_head` preserves the
   selected branch's actual lifetime. `as_both` only accepts Buffered plans.
   Endpoint calls return `Result[Result[O, E], ResponseFailure]`;
   authentication and business handlers return `Result` without changing the
   wire representation.
8. The executor enforces retry count, replay source and remaining budget even
   for a custom decision function. Idempotency comes from the method or the
   explicit `replay_safe` attribute; a header alone is not proof. Vendor retry
   rules belong to the vendor SDK.
9. `Client::close` records closure before closing its shared backend and is
   idempotent. A planned retry checks closure before backoff and on waking,
   before another limiter acquire or attempt; closure returns the last
   attempt's outcome exactly as `Stop` would, including a selected streaming
   consumer. It does not interrupt an already running `Clock.sleep`; no wake
   or cancellation port is required. Later sends fail with `Closed` in phase
   Pool before admission. The completed attempt still releases its Admission.

## Incremental parsers

| Parser | Rules |
|---|---|
| SSE (`gaato/mttp_core/sse`) | Every byte split, CR/LF/CRLF, split UTF-8, bounded retained fields, sticky finish |
| Multipart boundary scanner (`gaato/mttp_core/multipart`) | Matches across chunk boundaries without emitting a colliding delimiter |

## HTTP/1 codec (`gaato/mttp_core/h1`)

The codec follows the message syntax and framing of
[RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html), with strict CRLF and a
stricter rejection of duplicate Content-Length, even identical duplicates.
CL+TE is rejected as smuggling. Only the single transfer coding `chunked` is
supported. Header values retain Latin-1 octets and duplicate fields in order;
obs-fold, controls and whitespace before a header colon are refused.

`HeadDecoder` scans incrementally in linear time. `scan_head` is the stateless
alternative for an already available buffer. Head and chunk decoder errors
are sticky. `consumed` excludes body or pipelined bytes after completion.
Chunk payloads are emitted without buffering a declared chunk's entire size;
size lines and trailer storage have independent byte and count limits.
`parse_request_head` and `parse_response_head` return the read-only structs
`ParsedRequest` and `ParsedResponse`.

Wire writers reject invalid fields and framing instead of emitting unsafe
bytes, so they raise `ParseError`. They replace CL/TE using the supplied
framing. A successful CONNECT's `NoBody` describes the HTTP message only; the
engine must hand off the remaining tunnel bytes. Both engines (`h1client`,
`h1server`) decide framing with the same `request_framing` and
`response_framing`.

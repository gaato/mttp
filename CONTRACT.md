# Contracts

What code on either side of the `gaato/mttp_core` traits may rely on, and what the
sans-IO parsers guarantee. A backend, a runtime adapter, a test double or a
wrapper that keeps these rules can be used with every engine and client in the
family; a consumer written against them needs nothing more.

The traits live in two packages of `gaato/mttp_core`: the root (`Backend`,
`BodyStream`, `SendOptions`) and `rt` (Clock, Timer, Gate, Conn, Dialer,
Signal, Coordination). The doubles are in `gaato/mttp_core/sim`, the deterministic
scheduler in `gaato/mttp_core/driver`, and the runtime implementations in
`gaato/mttp`. The policy rules at the end (client attempts) belong to
`gaato/mttp_core/client`.

Shared checks: `@sim.check_conn`, `check_coordination_contract`,
`check_body_stream_contract` and `check_backend_contract` run against the sim
doubles and against gaato/mttp's adapters; `check_backend_contract` also runs
against gaato/mttp_ng's `H2Backend`. Transport-specific rules (wire
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

`read_some() async -> Bytes? raise TransportError`; `close() -> Unit`;
`trailers() -> Headers`, empty by default.

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
7. `trailers()` gives the trailer section that came after the bytes (RFC
   9110, section 6.5) once `read_some` returned EOF, and keeps giving it
   after `close`; before EOF, and for a body without one, it is empty. A
   sender reads it after EOF and sends it: HTTP/1.1 in the last chunk of a
   chunked body only (a body with a declared length goes with
   Content-Length, and its trailers are not sent), HTTP/2 and HTTP/3 as a
   HEADERS frame after the body. A trailer section a sender cannot carry
   (invalid fields; Content-Length, Transfer-Encoding, Host, Connection,
   Trailer; and over HTTP/2 and HTTP/3 the other connection-specific
   fields and TE) fails the message as the producer's failure does, so it
   does not end as whole. A wrapper that passes a body through passes its
   trailers on, at its own EOF, which may come after its source's (an
   encoder still has bytes to hand out) or not at all (a check at the end
   failed); trailers are never merged into the head. The JavaScript
   fetch backend and Workers server have no trailers (fetch exposes none),
   and `httpcache` does not store a response that had them, since a stored
   body is bytes.

## Connections and coordination

Conn reads return nonempty chunks of at most `max_len`; EOF permanently ends
only the read half. A read raises `IncompleteClose` when the transport ended
without its own end-of-stream signal (a TLS peer that closed the connection
beneath without close_notify); like EOF it is permanent, and every later read
raises it again until close. A caller whose message framing delimits the
message treats it as EOF; only a message delimited by the close itself is
truncated (RFC 9112, section 9.8). Writes consume all supplied bytes. One reader and one
writer may run concurrently. Close is idempotent and wakes pending operations;
a write after close raises TransportError. A write that raises `Closed` sent
none of its bytes: the connection was already closed, by this end or by the
peer, as a TLS session the peer shut down refuses writes. Any other write
failure may follow a partial write. The HTTP/1.1 client relies on this to
send a request on another connection when a reused one refuses its first
write. Cancellation finishes an operation's cleanup before another operation
in that direction begins.

`rt.Conn` has no write-half shutdown, because core/async offers none for
sockets or TLS. `@sim.SimConn::shutdown_write` exists only to test how peers
react to a half-closed stream.

A successful Dialer TLS upgrade owns its input connection. A failed upgrade
leaves that connection owned by the caller, which closes it. The runtime
`TcpDialer` verifies certificates according to its root-package
`gaato/mttp.Trust` value (`System`
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

`Coordination.protect(work~)` runs bounded work with caller cancellation
deferred. Protection is task-local and nests: returning from an inner region
does not unprotect its caller. A pending cancellation stays pending after
return and is delivered at the next unprotected cancellable suspension, as
with core/async's `protect_from_cancel`; transport errors retain their
identity. Work must have its own deadline because the caller cannot interrupt
it. Children remain independently cancellable, so a Timer can expire inside
protection. WebSocket control replies use this to finish a frame before a
cancelled recv can be retried; the deadline also closes the Conn to wake a
blocked write. Application data sends remain cancellable.

The receiving parser never performs blocking Pong writes. Its independent
monitor owns them; recv joins any started protected write before returning
or unwinding. Dispatch/completion bookkeeping can be awaited, but an active
or queued write cannot hold up peer input: two full pipes must keep draining.
For an otherwise free writer, a Pong completion races one bounded 64 KiB
read before parsing the rest of a Ping batch, since a writable socket may
still suspend until its I/O completion. Available input resumes parsing
immediately; blocked writes retain only the latest pending Pong. Read-ahead
has one reader, survives cancellation and is drained before more transport
input, so bytes cannot be lost or queued without bound.
After a message becomes ready, a started peer control frame is drained too:
our own Pong completing does not imply that the peer's partial Pong write
has completed. The next data head is deferred rather than overwriting the
committed message. This keeps byte-at-a-time backpressured peers live while
retaining one message, one read-ahead chunk and one fixed header.
Once our Pong has finished, an incomplete next header cannot delay a ready
message; that header stays buffered for the next recv. A speculative read
failure is retained after the parser and read-ahead bytes, so every complete
message buffered before it is delivered before that failure is reported.

## Backend

`send(Request, SendOptions) async -> Response raise TransportError`;
`close() -> Unit`.

1. **Validation first.** An invalid URL, header, method or body framing is
   refused before any I/O with `TransportError(kind=Invalid, phase=Pool, ..)`,
   which is unsent.
   Header values may be empty and contain interior SP/HTAB, but must not
   start or end with SP/HTAB: recipients strip edge whitespace, changing
   the caller's value. Trim it before setting the field.
2. **Phases are honest.** Every failure carries the phase in which it
   happened. A failure reported in Pool or Dial means no request byte reached
   the peer; `is_unsent` relies on this. A peer that says it did not process
   the request (HTTP/2's REFUSED_STREAM or a stream above a GOAWAY's last
   stream identifier, HTTP/3's H3_REQUEST_REJECTED) is reported with kind
   `Refused` in the phase the exchange had reached, not as Pool: `is_unsent`
   counts `Refused` too, because the request may be sent again whatever its
   method. gaato/mttp_ng's engines see the frames themselves and report
   refusals so; a stream whose HEADERS never went out fails in Pool. A
   backend whose engine cannot tell such a refusal from a connection lost
   after the request went out reports it as not unsent, the safe side.
3. **Request bodies.** The backend takes a stream body at most once and closes
   it on success, failure and cancellation. It performs the stream's first
   read before writing the request head, so a failing stream or one falsely
   declared empty sends nothing.
4. **Response ownership.** A returned Response's body belongs to the caller,
   who reads it to EOF or closes it. Closing early releases what the
   exchange holds (its connection, or its stream on a multiplexed one);
   whether a connection may be used again is the engine's decision, never
   the caller's.
5. **Raw bytes.** A backend moves bytes. It does not follow redirects, retry,
   store cookies or undo content codings; wrappers that do so say so in their
   name and documentation (FollowRedirects, Cookies, Decompress). An engine
   that sends a request again by itself (as libcurl does) is let do so only for a
   request that `is_idempotent` accepts, and its backend's documentation
   says so; those sends are not the Client's retries and its budget does
   not count them. JS fetch is
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
10. **Early data.** A backend that sends requests in TLS 1.3 early data
    (0-RTT, as HTTP/3 over QUIC may) sends there only requests that may be
    replayed: idempotent ones or ones marked `replay_safe`
    (`@mttp_core.is_idempotent`), because an attacker can replay early data
    (RFC 8470, section 3).
11. **Protocol.** A backend that knows which protocol carried a response
    records it under the `@mttp_core.protocol` attribute as its ALPN
    identifier (`http/1.0`, `http/1.1`, `h2`, `h3`). One that cannot know,
    such as JS fetch, leaves it unset.
12. **Attributes and upgrades.** A backend or wrapper preserves response
    attributes it does not own, because they can carry protocol ownership.
    An HTTP/1 client accepts 101 only if the request's Connection contains
    upgrade and its Upgrade field is present. It returns `rt.upgraded` with
    a take-once connection and every byte read past the head. The slot remains
    held until that connection is closed, exactly once; it is never pooled.
    Wrappers never retry, follow or decode a 101 response.
    Discarding an attribute-bearing response also takes and closes its
    unclaimed upgrade (`rt.close_unclaimed`), because closing an empty HTTP
    body does not dispose of protocol ownership. Engines and Client retain
    only unclaimed hand-overs: take or discard unregisters immediately, close
    reclaims the remainder, and late arrivals after close are reclaimed too.
    Connections already claimed belong to the caller and survive Client close.
13. **Phase events.** A backend may report the points an exchange reaches
    (`@mttp_core.PhaseEvent`: `Dialed(addr)`, `TlsDone`, `Pooled(reused)`,
    `Written`, `FirstByte`) to the request's `@mttp_core.on_phase` attribute,
    for observation only. It reports them in that order, each at most once
    per send, and never after the send returned or raised; a point it cannot
    see, or reached out of order (as `Written` after an early response's
    `FirstByte`), is not reported. Reporting nothing is valid: JS fetch sees
    no connections and reports none. A wrapper passes request attributes on,
    so the callback reaches the engine beneath it.

A backend written outside this repository, for example over another HTTP
engine, passes `@sim.check_backend_contract(make_backend)` from
`gaato/mttp_core/sim`, which exercises these rules (including rule 6's phase) on
the target it runs on. A wrapper also supplies `wrap=inner => Wrapper::new(inner)`
so the checker can inject upstream response attributes and verify preservation
on both 200 and 101 without a network peer.

`mttp/backend.AsyncBackend::new` accepts optional `rt.Clock` and
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
5. With a dictionary store, the RFC 9842 headers `Decompress` adds itself
   go only to https or loopback URLs of the dictionary's origin, and only
   when the caller set neither Accept-Encoding nor Available-Dictionary
   (headers a caller sets are sent as they are). It decodes dcb and dcz only
   after their header names the dictionary it offered, and stores a
   dictionary only from a 200 read to its end, within the store's bounds.

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
   `nocancel` section (`cancel_and_join`, `park_check_cancel`) or inside
   `Driver::protect`; a deadline
   requests cancellation and may be followed by the required cleanup time.
   Protection increments a task-local mask, restores it on every exit and
   does not clear the cancellation request. Driver shutdown preserves timers
   while protected work remains, advancing virtual time for bounded cleanup;
   ordinary cancellation cleanup still advances no time.
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
8. **Runtime parity.** gaato/mttp's `ClockTimer`, `SemaphoreGate` and
   `RuntimeCoordination` satisfy the Timer, Gate and Coordination rules above
   with the same contract tests as the sim doubles, including the
   cancellation cases.
9. **Schedules.** Without a `Schedule`, ready tasks run in FIFO order and due
   timers fire in (deadline, arming) order. With one, the driver chooses only
   where core/async could also order things differently: a task woken inside
   `io_event` (the sim connections deliver bytes and EOF that way) may be
   overtaken by tasks that became ready after it, never across a time
   advance, including a manual advance while tasks are ready. Timers always
   fire in (deadline, arming) order, including equal deadlines armed at
   different instants. Spawn, pause, signal, gate and join wakes and
   cancellation keep their FIFO order, as core/async's run queue and timer
   set keep it. Code under test that is correct on the runtime is correct
   under every schedule.

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
10. A circuit breaker refuses with `Kind::CircuitOpen` in phase Pool, so the
    refusal is unsent, and `RetryRule` never retries it: an immediate retry
    would meet the same open circuit. `AuthRefresh` sends a request at most
    twice per `send` and never refreshes one marked `auth_refreshed`.
    `Client::sse_reconnecting` checks closure before and after each reconnect
    wait, as rule 9 does for a retry, and returns the last end as `GaveUp`.
10. With `events`, each attempt reports `AttemptStart` after admission,
    then its backend's phase events and its redirect hops, then `AttemptEnd`
    wherever the observer is called, cancellation included. Nothing about an
    attempt is reported after its `AttemptEnd`: the Client drops later phase
    and redirect reports. A `Retry` is reported when the retry is sent, after
    its wait, between the two attempts.

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
supported; a request with `chunked` before another coding is malformed (RFC
9112 section 6.3), any other coding unsupported. Header values retain Latin-1 octets and duplicate fields in order;
obs-fold, controls and whitespace before a header colon are refused.

Response readers preserve three-digit statuses 100–999. Invalid HTTP
statuses 600–999 are treated as server failures (RFC 9110, section 15),
retaining the original number in response heads and failure values. They
are non-2xx for buffered and streamed readers and undeclared endpoint
outputs. Retry status rules still match the original number explicitly;
matching 500–599 does not include 600–999. Codes below 100, two or four
digits, and nondigits are refused. Writers still refuse statuses above
599; the server engine replaces handler statuses outside 200–599 with 500,
except the explicit server hand-over below.

`HeadDecoder` scans incrementally in linear time. `scan_head` is the stateless
alternative for an already available buffer. Head and chunk decoder errors
are sticky. `consumed` excludes body or pipelined bytes after completion.
Chunk payloads are emitted without buffering a declared chunk's entire size;
size lines and trailer storage have independent byte and count limits.
The decoded trailer section is the body's (`BodyStream` rule 7) on both
engines; `encode_last_chunk` writes one, refusing the fields the decoder
refuses.
`parse_request_head` and `parse_response_head` return the read-only structs
`ParsedRequest` and `ParsedResponse`.

Wire writers reject invalid fields and framing instead of emitting unsafe
bytes, so they raise `ParseError`. They replace CL/TE using the supplied
framing. Every supplied field is checked before replacement, including
the prohibition on leading/trailing SP or HTAB in a nonempty value.
A successful CONNECT's `NoBody` describes the HTTP message only; the
engine must hand off the remaining tunnel bytes. Both engines (`h1client`,
`h1server`) decide framing with the same `request_framing` and
`response_framing`.

The HTTP/1 server engine adds framing, Connection and, by default, Date to
every final response, including errors and HEAD/204/304. A handler's Date
is preserved. `serve_conn(auto_date=false)` disables the automatic field;
`mttp/server.serve` passes the same option through. Date is IMF-fixdate from
the injected Clock, cached per connection and second. The interim
100 Continue carries no automatic Date. An invalid handler header value
becomes 500 before its response is written and is reported to `on_error`.

## Server connection hand-over

`rt.upgrade` is a server-side response attribute holding an async callback
`(&rt.Conn, Bytes, () -> Bool) -> Unit noraise`. An HTTP/1.1 engine writes
101 only when that callback is present and the request contains Upgrade and
Connection: upgrade. A 101 without both conditions becomes 500. An Upgrade
request with a nonzero Content-Length or transfer coding is refused with 400
before invoking the handler, including with Expect: 100-continue.

The engine writes only the 101 head, joins its HTTP peer reader and passes
the connection and every unread byte, in order, to the callback. No HTTP
header, body or handler deadline covers the callback. The listener retains
the max_connections slot until callback completion; its stopping probe turns
true on shutdown and drain_ms remains the outer bound, after which the
connection is closed and the callback cancelled and joined. The ws helper
polls that probe at most every 250 ms and sends Close 1001, with the session's
close_timeout_ms bounding its wait. A shorter drain_ms takes precedence.

Router-as-Backend isolates ordinary local attributes as before. For a 101 it
runs the server callback over a byte pair and returns only `ws.ws_session`,
holding the client-role codec. This requires injected clock, timer,
coordination and background scheduling ports; without them the send fails
with Invalid in Head. The supplied scheduler must own and join its tasks.
Each byte-pair direction retains at most 64 KiB and backpressures its writer.
The caller owns the returned session; close or abort it independently of the
empty response body. Closing the Router turns the callback's stopping probe
true. Neither the server callback nor other server-local attributes escape.

## Server request attributes

`connection_scheme` is the scheme the connection was accepted under, `http`
or `https`, never taken from the request target: an absolute-form target
may say `https` on a cleartext connection, and the request's URL keeps what
the client wrote. Server adapters set it where they know it:

1. h1server (`serve_conn`, and so `@server.serve`) from its `scheme` argument.
2. Router-as-Backend from the in-process request's own scheme.
3. gaato/mttp_ng's HTTP/2 server (`serve_h2_conn`) from its `scheme`
   argument, and its HTTP/3 server always as `https`. Both also set
   `protocol` (`h2`, `h3`) and `remote_addr`.

An adapter that does not know it leaves it unset. The JS fetch hosts do: a
host's request URL may keep an absolute-form target's scheme as the client
wrote it (Deno does), so it does not say whether TLS carried the request. A
policy that needs a secure context (RFC 9842's `dictionary_compress` by
default) trusts only `https` here, not a loopback `remote_addr`, which a
local reverse proxy also is, and fails closed otherwise; a deployment
behind a proxy that ends TLS, on a JS host, or on localhost supplies its
own verdict.


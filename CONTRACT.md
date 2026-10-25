# Contracts

What code on either side of the `gaato/mttp` traits may rely on, and what
the sans-IO parsers guarantee. A backend, a test double or a wrapper that
keeps these rules can be used with every client here; a consumer written
against them needs nothing more.

This ledger distinguishes the local implementations already checked from
runtime adapters still to be implemented. Shared cross-adapter contract
suites will be added with those adapters; current evidence is the named
package tests below.

## Clock

`sleep(Int) async -> Unit noraise`; `now_unix_ms() -> Int64`.

1. Nonpositive sleeps do not advance time. Cancellation propagates through
   the scheduler rather than an ordinary error.
2. `SimClock` shares its Driver's time; overlapping sleeps advance to the
   latest deadline, not the sum of durations.
3. `FakeClock` is explicitly a sequential accumulator: positive sleeps add
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
2. `SimGate` hands slots to queued callers in FIFO order. A queued caller
   cancelled before handoff removes itself without consuming a slot.
3. A caller cancelled after handoff still receives its slot and may install
   cleanup before cancellation is delivered at its next suspension.
4. Extra releases are capped at capacity. Negative capacity is zero.

## BodyStream

`read_some() async -> Bytes? raise TransportError`; `close() -> Unit`.

1. Chunks are nonempty. EOF is permanent; reads after close return EOF.
2. Close is idempotent. The consumer closes on success, error and cancellation.
3. `StreamBody::take` grants one reader; copies of the containing body share
   acquisition state. A second take fails with `Unreplayable`.
4. A declared negative length is invalid before any read. A taken stream
   refuses a crossing chunk or premature EOF, closes its source, and does
   not expose bytes beyond the declared length.
5. `read_bounded` closes on every exit, rejects empty chunks, and refuses the
   first chunk that would exceed the limit using overflow-safe arithmetic.
6. Concurrent reads on the same stream are outside this contract.

## Implementations checked against the rules

| Implementation | Holds | Notes |
|---|---|---|
| FakeClock, SimClock, SimTimer, SimGate | Local rules above | `clock/fake/clock_test.mbt`; no runtime adapter has been checked yet |
| StreamBody and taken stream | Acquisition, declared length, close, sticky EOF | `model/body_test.mbt`; read-loop cancellation also exercised by `testing/feed/feed_test.mbt` |
| Multipart body | Boundary collision, ownership and cleanup | `multipart/stream_test.mbt`, ported from runtime-tests |
| Feed | Scripted data, EOF, error, virtual delay and cancellation | `testing/feed/feed_test.mbt` |
| Client and Backend wrappers | Raw validation, body ownership, one release per successful acquire, head preservation on reader failure, explicit retry policy, replay refusal, deadlines | `client/client_test.mbt`, `client/readers_test.mbt`, `client/loop_test.mbt` |
| WindowLimiter | Gate handoff and cancellation, shared server windows, global exemptions, pacing, lazy eviction | `client/ratelimit/limiter_test.mbt`, `client/ratelimit/rate_limit_wbtest.mbt` |

## Client attempts

1. Retrying is opt-in. RetryDecider sees transport, rejected-status and
   buffered-reader errors. Streaming callbacks run once after release and
   observation, and their errors are never retried.
2. Every acquire that returns has exactly one release. Cancelled admission
   waits have none. Release uses the received head even when reading fails.
3. Body factories run only after admission and a deadline check. Without a
   factory, stream requests cannot retry, regardless of the decider.
4. A release failure on success reaches the caller and closes the held body.
   During failure or cancellation, release failure does not replace the
   original outcome. Observers run once after release is attempted.
5. A total deadline is checked before admission and again after it. Admission
   itself is not interrupted by that deadline. A fallback Timer limits the
   exchange, with accepted streaming callbacks outside it.

## Incremental parsers

| Parser | Rules | Checked by |
|---|---|---|
| SSE | Every byte split, CR/LF/CRLF, split UTF-8, bounded retained fields, sticky finish | `sse/parser_test.mbt`, `sse/encode_test.mbt` |
| Multipart boundary scanner | Matches across chunk boundaries without emitting a colliding delimiter | `multipart/boundary_scan_wbtest.mbt`, `multipart/stream_test.mbt` |
# HTTP/1 codec

The `h1` codec follows the message syntax and framing of RFC 9112
(https://www.rfc-editor.org/rfc/rfc9112.html), with strict CRLF and the design's
stricter rejection of duplicate Content-Length, even identical duplicates.
CL+TE is rejected. Only the single transfer coding `chunked` is supported.
Header values retain Latin-1 octets and duplicate fields in order; obs-fold,
controls and whitespace before a header colon are refused.

`HeadDecoder` scans incrementally in linear time. `scan_head` is the stateless
alternative for an already available buffer. Head and chunk decoder errors
are sticky. `consumed` excludes body or pipelined bytes after completion.
Chunk payloads are emitted without buffering a declared chunk's entire size;
size lines and trailer storage have independent byte and count limits.

Wire writers reject invalid fields and framing instead of emitting unsafe
bytes, so they raise `ParseError` (a deliberate refinement of the design's
nonraising sketch). They replace CL/TE using the supplied framing. A successful
CONNECT's `NoBody` describes the HTTP message only; the adapter must hand off
the remaining tunnel bytes. Socket ownership and timeouts remain adapter work.

The socket backend takes an outgoing stream and performs its first read
before writing the request head. This preserves the mature upload contract:
nested multipart ownership failures and streams falsely declared empty fail
without sending request bytes. An empty stream is read once, whether its
length is known or unknown. The stream is closed on success, failure and
cancellation (`mttp-net/src/backend/upload_test.mbt`).

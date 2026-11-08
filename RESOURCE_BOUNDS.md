# Resource bounds

What a long-running client, server or parser built on `gaato/http`,
`gaato/http-async`, `gaato/mttp` or `gaato/mttp-digest` can accumulate, and
what keeps each structure from growing without limit. The rule: **every
structure that grows with input from the network, a peer, or the number of
requests, buckets, connections or pending calls is listed here with its
bound**. A new one, such as a map keyed by names that arrive from outside or a
buffer filled from a stream, needs a row before it ships.

A bound is either a limit the code enforces, or the rate of the input times
how long an entry lives, where both are themselves bounded. Rows of the second
kind say what that product is. Bounded by default: a limit has a default, and
input past it is refused rather than degraded.

A body that may be compressed has two bounds, and each gets its own row: the
bytes read from the wire (enforced by the connection engine) and the bytes
after decoding (enforced by the decoder and the mttp client). One row for both
would hide a decompression bomb that stays under the wire limit.

**Every row of "Enforced limits" names a test that checks the bound**, in its
Tests column: a backticked file path, then the quoted names of that file's
tests, as in `` `http/src/h1/head_test.mbt`: "first", "second" ``. A test
counts only if it drives the structure to its limit and one past it, or pins a
default the row states; one that merely uses the feature does not.
`scripts/bounds_check.mbtx`, run by `scripts/gates.sh`, enforces the naming: it
fails when a row names no test or a named test is not declared in the named
file. Whether a named test really reaches the bound is checked in review. The
other tables describe where no limit is enforced, so they stay prose.

Test helpers (`gaato/http/sim`, `gaato/http/driver`, `gaato/mttp/testing`)
record what a test feeds them and are not listed, except the limits that keep
a test from hanging.

## Enforced limits

| Structure | Bound | On overflow | Tests |
|---|---|---|---|
| `http` buffered stream read (`read_bounded`) | The caller's explicit limit; a negative limit is refused | Closes the stream and raises `TooLarge(limit)` in phase Body at the crossing chunk, before buffering it; overflow-safe | `http/src/body_test.mbt`: "read bounded accepts exact limit and closes at crossing chunk", "read bounded closes on invalid limits and empty chunks" |
| `http` taken `StreamBody` with a declared length | The declared length; a negative one is refused before any read | Raises `Protocol` in phase Body at the crossing chunk or a premature EOF and closes the source; no byte past the length is exposed | `http/src/body_test.mbt`: "stream body rejects negative short long and empty chunks" |
| `http` decoded form pairs (`form_urldecode`) | `max_pairs`, default 256 nonempty pairs; the input byte bound belongs to the caller that read the body | Raises `TooLarge(limit)` in phase Body before decoding an excess pair | `http/src/form_decode_test.mbt`: "form pair limit accepts exact bounds and defaults to 256" |
| `http/h1` head bytes (`HeadDecoder`, `scan_head`, `parse_request_head`, `parse_response_head`) | `Limits.max_head_bytes` (the `HeadDecoder` `max`), default 16 KiB including the start line, the final CRLF CRLF and any empty lines skipped before a request line; a negative limit is refused | Raises `HeadTooLarge` at the first byte past the limit, before buffering it; the decoder's error is sticky and its buffer is released | `http/src/h1/limits_test.mbt`: "head limit accepts 16 KiB and refuses one byte more", "empty lines before a request line count against the head limit"; `http/src/h1/head_test.mbt`: "head scanner and accumulator enforce exact byte and field limits" |
| `http/h1` fields per head | `Limits.max_headers`, default 100, start line excluded | Raises `HeadTooLarge` before parsing the excess field | `http/src/h1/limits_test.mbt`: "head field limit accepts 100 fields and refuses 101"; `http/src/h1/head_test.mbt`: "head scanner and accumulator enforce exact byte and field limits" |
| `http/h1` chunk-size line (`ChunkedDecoder`), extensions included | `Limits.max_chunk_line_bytes`, default 4 KiB including CRLF; chunk payloads are never buffered | Raises `HeadTooLarge` at the first byte past the limit; sticky | `http/src/h1/limits_test.mbt`: "chunk size line limit accepts 4 KiB and refuses one byte more"; `http/src/h1/chunked_test.mbt`: "chunk lines trailers and field counts enforce exact limits" |
| `http/h1` trailer section bytes (`ChunkedDecoder`) | `Limits.max_trailer_bytes`, default 16 KiB including the final CRLF | Raises `HeadTooLarge` at the first byte past the limit; sticky | `http/src/h1/limits_test.mbt`: "trailer section limit accepts 16 KiB and refuses one byte more"; `http/src/h1/chunked_test.mbt`: "chunk lines trailers and field counts enforce exact limits" |
| `http/h1` trailer fields (`ChunkedDecoder`) | `Limits.max_headers`, default 100, counted separately from the head | Raises `HeadTooLarge` before parsing the excess field; sticky | `http/src/h1/limits_test.mbt`: "trailer field limit accepts 100 fields and refuses 101"; `http/src/h1/chunked_test.mbt`: "chunk lines trailers and field counts enforce exact limits" |
| `http/driver` steps of one `Driver::run` (and of manual `step` calls since it started) | `max_steps`, default 100 000 000 | `step` raises `DriverError(NoQuiescence(steps~))`; `run` cancels and unwinds the live tasks first | `http/src/driver/driver_test.mbt`: "max_steps allows exactly that many steps per run", "livelock raises NoQuiescence" |
| `http/driver` rounds of cancellation when `run` ends | `max_unwind_rounds` = 8 | `run` raises `DriverError(UnwindIncomplete(live~))`; the surviving tasks stay live | `http/src/driver/driver_test.mbt`: "unwinding gives up after max_unwind_rounds rounds" |
| `http/driver` timer callbacks per run | `max_steps`, independent of task steps | Raises `NoQuiescence`, discards timers and cancels live tasks | `http/src/driver/driver_test.mbt`: "self-rearming due timers obey a callback budget" |
| `http/driver` cleanup steps per cancellation round | The larger of `max_steps` and twice the number of live tasks at the round's start | Ends the round; at most `max_unwind_rounds` rounds | `http/src/driver/driver_test.mbt`: "exhausted execution budget still unwinds ten thousand tasks", "unwinding gives up after max_unwind_rounds rounds" |
| `http/sim` sized generators (`gen_text`, `gen_headers`) | 128 text pieces (at most 256 UTF-16 units) and 32 header pairs, whatever quickcheck size is requested | Clamps the size before generating a sample | `http/src/sim/gen_test.mbt`: "generators clamp caller sizes and preserve empty input" |
| `http/sim` reads of `check_body_stream_contract` | `max_reads`, default 1024 reads, the read that returns EOF included | Stops reading and raises `Failure` naming the read budget, so a stream that never ends fails the check instead of hanging it | `http/src/sim/contracts_test.mbt`: "body stream check stops a stream after max_reads reads" |
| `mttp/sse` one event: its `data` lines, the `event` and `id` lines in effect, and the line being read | `max_event_bytes`, default 16 MiB, in raw bytes without line terminators; below 1 only blank lines pass | Raises `TooLarge(limit)` in phase Body and ends the stream; events the same chunk completed earlier are returned first and the next `feed` or `finish` raises | `mttp/src/sse/parser_test.mbt`: "one event is bounded by the lines it keeps plus the line being read", "the default bound is 16 MiB", "an overflow after events in the same chunk raises on the next call" |
| `mttp/sse` reconnection delay (`retry`) | One hour | Clamped: a longer or overflowing digit run reads as 3 600 000 ms | `mttp/src/sse/parser_test.mbt`: "a retry hint past an hour reads as an hour", "the reconnection time takes effect when read and outlives the stream" |
| `mttp/multipart` boundary and the scan of stream parts | 1 to 70 `bchars`, so the delimiter is at most 74 bytes; the scan keeps a match counter, never part bytes | `InvalidBoundary` before any byte is encoded; a stream part containing the delimiter raises `Protocol` in phase Body before the delimiter's last byte is returned | `mttp/src/multipart/multipart_test.mbt`: "boundary validation and header quoting"; `mttp/src/multipart/boundary_scan_wbtest.mbt`: "BoundaryScan finds the delimiter as body_collides does", "BoundaryScan agrees with body_collides however the body is chunked"; `mttp/src/multipart/stream_test.mbt`: "a stream part containing the boundary fails before the collision is sent" |
| `mttp/cookie` stored entries | `max_per_domain`, default 50, and `max_total`, default 3000; caps below 0 count as 0 | Evicts expired cookies first, then the least recently accessed (cookies that are not Secure first for the per-domain cap) | `mttp/src/cookie/jar_wbtest.mbt`: "the default caps are 50 cookies per domain and 3000 in all", "zero or negative caps keep nothing", "the per-domain cap evicts the least recently accessed cookie", "the total cap evicts expired cookies, then the least recently accessed" |
| `mttp/cookie` accepted name and value, and each attribute | 4096 bytes of name and value together, 1024 bytes per attribute | Ignores the cookie, or the attribute, as RFC 6265bis says | `mttp/src/cookie/set_cookie_wbtest.mbt`: "a cookie is ignored past 4096 bytes of name and value and an attribute past 1024" |
| `mttp/cookie` lifetime | 400 days | Clamps `Max-Age` and `Expires` | `mttp/src/cookie/jar_wbtest.mbt`: "lifetimes are cut to 400 days" |

## Bounded by rate and lifetime

| Structure | Grows with | Bound |
|---|---|---|

## Left to the caller

Growth that follows what the caller asks for, not what the network sends.

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| `http` headers, URL strings, attribute maps and byte bodies | Values explicitly constructed by the caller | Parsers and engines impose the network input limits; these value constructors do not consume network input. |
| `http` URI builder | Caller-provided components | Interpolation is linear in the supplied text and stages one query parameter. |
| `http/h1` payload pieces of one `ChunkedDecoder::feed` and the bytes of a written head | The bytes the caller feeds in one call; the fields the caller writes | The decoder returns copies of the payload bytes of that call and keeps none of them; the writers serialize caller-built values and validate them. |
| `http/driver` ready queue, live-task map, timer heap | Tasks the test spawns and timers it arms | A test helper: the test decides how many; `max_steps` stops a run that keeps spawning. Cancelled timers stay in the heap until they reach its top or `run` ends. |
| `http/sim` recordings and queues: `FakeClock::slept`, `ScriptedConn` writes and script, `ScriptedDialer` connections, dials and TLS hosts, `SimConn` pipes, `SimGate` waiters, `Feed` script | What the test writes, scripts and spawns | Test helpers: the test decides how much; a `SimConn` write never blocks, so a test that floods one end without reading the other grows its pipe. |
| `mttp/jsonkit` builders and decoded fields | Fields the caller writes; a JSON tree already parsed | The builder grows only with the caller's writes; decoders read a tree whose bytes the reader that parsed it bounded. |
| `mttp/sse` events returned by one `feed` | The chunk the caller feeds | Each event is bounded above, and each takes at least six bytes of input (`data`, a line end and a blank line). |
| `mttp/multipart` framing and part descriptors | Caller-supplied parts | Framing and in-memory bodies are what the caller passed; a stream body holds the part streams and the part being read, and the boundary scan above. |
| `mttp/client/retry` decisions and Retry-After values | One response's headers | Decisions are pure and keep nothing; the Retry-After parsers read one header value, linear in its length, and saturate the result. |

## Known gaps

Growth the library does not bound yet, with what limits it in practice and how
it could be fixed.

| Structure | Grows with | What limits it | Suggested fix |
|---|---|---|---|

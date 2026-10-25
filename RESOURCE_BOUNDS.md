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
| `h1` retained head bytes and fields | Default 16 KiB including CRLF and 100 fields | Raises `HeadTooLarge`; accumulator failures are sticky and release the unfinished buffer | `mttp/src/h1/head_test.mbt`: "head scanner and accumulator enforce exact byte and field limits" |
| `h1` chunk-size lines and trailers | Default 4 KiB per size line, 16 KiB for all trailers including CRLF, 100 trailer fields | Raises `Malformed` and refuses further input; data chunks are emitted without accumulating their declared length | `mttp/src/h1/chunked_test.mbt`: "chunk lines trailers and field counts enforce exact limits" |
| `model` decoded form pairs | `max_pairs`, default 256 nonempty pairs; input byte bound belongs to caller | Raises `TooLarge` before decoding an excess pair | `mttp/src/model/form_decode_test.mbt`: "form pair limit accepts exact bounds and defaults to 256" |
| `client` line reader | `max_line_bytes`, default one MiB, plus one pending CR byte | Closes stream and raises `TooLarge`; previously delivered lines remain delivered | `mttp/src/client/combinators_test.mbt`: "line bounds refuse crossing bytes close streams and default to one MiB", "line reader handles every byte split including UTF-8 and CRLF boundaries" |
| `client` redirect history and followed hops | `max_redirects`, default 10; no response bodies retained | Closes the last intermediate response and raises `TooManyRedirects` | `mttp/src/client/redirect_wbtest.mbt`: "plan_redirect decides each hop"; `mttp/src/client/redirect_test.mbt`: "redirect refusals close received bodies and retain error classification" |
| `cookie` stored entries | Default 50 per domain and 3000 per jar; negative limits mean zero | Evicts expired entries, then least-recently-accessed entries (non-Secure first for per-domain overflow), preserving the cookie storage contract | `mttp/src/cookie/jar_wbtest.mbt`: "the default caps are 50 cookies per domain and 3000 in all", "zero or negative caps keep nothing", "the per-domain cap evicts the least recently accessed cookie", "the total cap evicts expired cookies, then the least recently accessed" |
| `cookie` accepted name/value and attribute bytes | 4096 bytes combined name/value, 1024 bytes per attribute | Ignores oversized cookies or attributes according to the cookie parser contract | `mttp/src/cookie/set_cookie_wbtest.mbt`: "a cookie is ignored past 4096 bytes of name and value and an attribute past 1024" |
| `cookie` lifetime | 400 days | Clamps Max-Age and Expires | `mttp/src/cookie/jar_wbtest.mbt`: "lifetimes are cut to 400 days" |
| `sse` retained event fields and unfinished line | `max_event_bytes`, default 16 MiB | Refuses with `TooLarge`; already completed events in the same chunk are delivered before the pending error | `mttp/src/sse/parser_test.mbt`: "one event is bounded by the lines it keeps plus the line being read", "the default bound is 16 MiB" |
| `model` buffered stream read | Explicit `read_bounded` limit | Closes the stream and raises at the crossing chunk | `mttp/src/model/body_test.mbt`: "read bounded accepts exact limit and closes at crossing chunk" |
| `client` unsuccessful response excerpt | 1 MiB | Truncates the diagnostic excerpt and closes the response | `mttp/src/client/client_test.mbt`: "unexpected statuses retain at most one MiB and close streams" |
| `client` buffered response reader | `max_body_bytes`, default 64 MiB | Closes the stream and raises `TooLarge` at the crossing chunk | `mttp/src/client/readers_test.mbt`: "byte readers enforce bounds for all body variants", "default response body limit is 64 MiB" |
| `client` call duration | Optional attempt `timeout_ms` and call `total_ms`; no default limit. Admission waits count against the total but are not interrupted | Raises `Timeout`, releases acquired admission, and closes received bodies. Backends enforce active deadlines; an injected Timer supplies fallback cancellation | `mttp/src/client/loop_test.mbt`: "an attempt that runs out of time is retried for GET not POST", "total timeout caps backoff and shrinks attempt budgets", "no attempt starts once total timeout has passed even with custom retry", "limiter wait uses total budget and still releases before observation" |
| `client` paginator collection | Explicit `collect(max)`; retains at most one unused page | Stops collection at max, preserving unused items for the next call | `mttp/src/client/paginator_test.mbt`: "Paginator each visits every item and collect keeps the unused rest" |
| `client/ratelimit` server-specified wait | One hour for parsed reset times and Retry-After | Clamps server wait to one hour; saturates timestamp arithmetic | `mttp/src/client/ratelimit/rate_limit_wbtest.mbt`: "a response cannot push a bucket's reset or the global block past an hour", "clamp_server_reset keeps resets within an hour and pulls later ones back", "an account-wide 429 cannot block past an hour" |
| `testing/driver` steps of one `Driver::run` (and of manual `step` calls since it started) | `max_steps`, default 100 000 000 | `step` raises `DriverError(NoQuiescence(steps~))`; `run` cancels and unwinds the live tasks first | `mttp/src/testing/driver/driver_test.mbt`: "max_steps allows exactly that many steps per run", "livelock raises NoQuiescence" |
| `testing/driver` rounds of cancellation when `run` ends | `max_unwind_rounds` = 8 | `run` raises `DriverError(UnwindIncomplete(live~))`; the surviving tasks stay live | `mttp/src/testing/driver/driver_test.mbt`: "unwinding gives up after max_unwind_rounds rounds" |
| `testing/driver` timer callbacks per run | `max_steps`, independent of task steps | Raises `NoQuiescence`, discards timers and cancels live tasks | `mttp/src/testing/driver/driver_test.mbt`: "self-rearming due timers obey a callback budget" |
| `testing/driver` cleanup steps per cancellation round | Maximum of `max_steps` and twice the number of live tasks at round start | Ends the round; at most eight rounds | `mttp/src/testing/driver/driver_test.mbt`: "exhausted execution budget still unwinds ten thousand tasks", "unwinding gives up after max_unwind_rounds rounds" |

## Bounded by rate and lifetime

| Structure | Grows with | Bound |
|---|---|---|
| `client/ratelimit` gate entries | In-flight requests holding or awaiting a pace group's gate | Removed when both holder and waiter counts are zero, including cancelled waits; at most the number of active groups |

## Left to the caller

Growth that follows what the caller asks for, not what the network sends.

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| `model` headers, URL strings, attribute maps and byte bodies | Values explicitly constructed by the caller | Parsers and backends impose network input limits; these value constructors do not consume network input. |
| `multipart` framing and part descriptors | Caller-supplied parts | Streaming retains framing plus the supplied byte bodies and stream handles; boundary scanning retains at most the delimiter length. |
| `testing/driver` ready queue, live-task map, timer heap | tasks the test spawns and timers it arms | A test helper: the test decides how many; `max_steps` stops a run that keeps spawning. Cancelled timers stay in the heap until they reach its top or `run` ends. |
| `client/ratelimit` states, server-key aliases and pace deadlines | Caller-supplied bucket and group names, optional server key parser | Lazy sweeps at doubled entry count (floor 64) or 60 seconds remove expired states, orphaned aliases and elapsed pace deadlines. States expire within one hour; idle maps persist until subsequent traffic. This preserves the mature limiter and provides no absolute key-count ceiling. |

## Known gaps

Growth the library does not bound yet, with what limits it in practice and how
it could be fixed.

| Structure | Grows with | What limits it | Suggested fix |
|---|---|---|---|

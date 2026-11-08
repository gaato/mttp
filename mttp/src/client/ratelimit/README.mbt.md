# gaato/mttp/client/ratelimit

`WindowLimiter` implements the client's `RateLimiter` on an injected
`gaato/http/rt.Clock`. Give it a response-header parser and pass it to
`Client::new(limiter=...)`. The client chooses the bucket from the
`rate_limit_bucket` request attribute, or `"default"`, and reads
`global_exempt` separately.

`rate_limit_headers` reads a nonnegative remaining count and a reset in
decimal seconds. A relative reset takes precedence over an absolute Unix
reset; missing or malformed relative values fall back to the absolute one.
The limiter consumes remaining quota at admission and records response
headers on release. A status of zero means no response and preserves state.

`Pace` groups buckets with a minimum interval between admissions.
`GlobalWindow` counts non-exempt admissions across buckets. On 429,
`LimitScope` selects a bucket block, a global block, shared parsed state, or
no change. Retry-After (including `retry-after-ms` and HTTP dates) overrides
the bucket reset; `default_retry_after_ms` handles missing or invalid values.
Every server-specified wait, including the fallback, is capped at one hour.

Optional `gate` factories provide fresh capacity-one FIFO `rt.Gate`s,
held from admission until release. This guarantees FIFO order inside a pace
group. Independent groups compete in scheduler order; without gates there
is no FIFO guarantee. Every successful acquire needs one release. A cancelled
wait consumes neither global nor bucket quota and returns any held gate.
The final global, bucket and pace checks commit without suspension.

`server_key` can map several caller buckets to one server window. Aliases
expire independently after one hour; expired state, aliases and pace deadlines
are swept on traffic, at doubling thresholds or every 60 seconds. Each map
(including active gate groups) has a fixed 4096-entry ceiling. New entries
beyond it raise `TransportError(TooLarge(4096))` after eviction of expired
entries; live state is retained. The phase is Pool on acquisition and Unknown
on release, because a response was already received. A release that refuses
recording still frees its gate. The caller controls the number of waiting calls.

The Clock port exposes Unix time rather than a monotonic clock. Internal
deadlines use nondecreasing elapsed time built from positive clock deltas
and completed sleeps. A backward clock adjustment cannot lengthen a wait by
the size of that adjustment; overlapping sleeps are not summed. Forward
wall adjustments still count as elapsed time. Unix time remains the input to
server date parsing and the time reported by `state`.

```mbt check
///|
test "parse a conventional quota head" {
  let parse = @ratelimit.rate_limit_headers(
    remaining="X-RateLimit-Remaining",
    reset_after_seconds="X-RateLimit-Reset-After",
  )
  assert_eq(
    parse(
      @http.Headers::of([
        ("X-RateLimit-Remaining", "2"),
        ("X-RateLimit-Reset-After", "1.5"),
      ]),
      1000L,
    ),
    Some({ remaining: 2, reset_at_unix_ms: 2500L, }),
  )
}
```

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

Each successful acquire returns an opaque `client.Admission` with its bucket
and a strictly increasing sequence assigned by this limiter. Pass that token
to release, including on transport failure or cancellation. A token belongs
to its issuing limiter. The first release removes it before processing the
head; duplicate releases are ignored, even if recording the first head failed.

Responses are ordered by admission identity, never by reset timestamps. A
key remembers the sequence of the response that last lowered remaining quota
or set/extended a block. A response may relax quota only if its own admission
sequence is greater than that restriction watermark. Otherwise it can only
lower remaining quota or extend a wait. Local quota consumption also records
its admission sequence: a response cannot undo a later admission, while a
request's own response can refresh the quota it consumed. Relative reset
delivery drift and different absolute resets therefore confer no permission
to replenish quota. The old conservative cohort debt is unnecessary.

A bucket 429's Retry-After is an independent block on the resolved key. It
replaces prior ordinary exhaustion, whether or not quota headers are present;
an ordinary reset cannot extend that Retry-After deadline. Stale positive
responses cannot reinstate ordinary quota during that block. An eligible
newer response can supply fresh quota for use after the block; responses
never shorten an active block, even when eligible to refresh quota.

`Pace` groups buckets with a minimum interval between admissions.
`GlobalWindow` counts non-exempt admissions across buckets. On 429,
`LimitScope` selects a bucket block, a global block, shared parsed state, or
no change. Retry-After (including `retry-after-ms` and HTTP dates) overrides
the bucket reset; `default_retry_after_ms` handles missing or invalid values.
Every server-specified wait, including the fallback, is capped at one hour.

Optional `gate` factories provide fresh capacity-one FIFO `rt.Gate`s,
held from admission until release. This guarantees FIFO order inside a pace
group. Independent groups compete in scheduler order; without gates there
is no FIFO guarantee. Every successful acquire needs one release with that
acquire's Admission. A cancelled
wait consumes neither global nor bucket quota and returns any held gate.
The final global, bucket and pace checks commit without suspension.

`server_key` can map several caller buckets to one server window. Every key
transition must preserve active blocks, restriction/consumption watermarks
and the lower remaining quota. Learning, changing or removing an alias first reconciles the
previously resolved state into the destination, even without parsed quota
headers. The source stays available to other buckets still using it. The
response is then reconciled using its own sequence, so a genuinely eligible
response may refresh quota after the transfer.

Aliases expire independently after one hour and survive quota resets and
sweeps of expired quota state. Expiry copies any live shared constraints to
the caller bucket before detaching. If the state map has no room for that
fallback, the alias retains its old route until a later lookup or sweep can
transfer it, or its constraints expire. A refused response transition leaves
the previous route and its constraints intact. These rules prevent a key
change or eviction from bypassing a block or replenishing quota.
Expired state, aliases and pace deadlines
are swept on traffic, at doubling thresholds or every 60 seconds. Each map
(including active gate groups and outstanding admission tokens) has a fixed
4096-entry ceiling, including deferred alias expirations and copied fallback
states. Outstanding bookkeeping holds at most 4096 tokens, including multiple
requests for the same bucket, and is removed by every first release,
including transport failures, ignored responses and recording refusals. New entries
beyond it raise `TransportError(TooLarge(4096))` after eviction of expired
entries; live state is retained. The phase is Pool on acquisition and Unknown
on release, because a response was already received. A release that refuses
recording still frees its gate. The caller controls the number of waiting calls.
Sequence numbers never wrap: exhaustion of Int64 raises `Invalid` in phase
Pool before admission, preserving quota and returning any acquired gate.

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

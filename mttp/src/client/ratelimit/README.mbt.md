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

Each key holds two optional, independent constraints: an ordinary quota with
remaining/reset and restriction/consumption sequences, and a Retry-After
block with its own deadline and admission sequence. They expire independently:
expiring a short block never discards a longer quota window, and expiring
quota never discards a longer block.

Responses are ordered by admission identity, never by reset timestamps. An
ordinary quota remembers the greatest sequence that restricted it; a block
retains the greatest sequence of its Retry-After responses. A response may
relax quota only if its own sequence exceeds both active authority watermarks.
It must also not predate local quota consumption: a request's own response
can refresh the quota it consumed, while an older response cannot undo later
admissions. Relative reset delivery drift confers no permission to replenish.

An eligible bucket 429 can replace prior ordinary exhaustion with its
Retry-After block, including when quota headers are absent. An ineligible
429 keeps newer ordinary quota and only adds or extends the independent block.
Stale positive responses cannot reinstate quota while a newer block fences
them. An eligible newer response can supply fresh quota for use after the
block; responses never shorten an active block. Ordinary quota cannot change
the block's deadline, but can independently require a longer admission wait.

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
transition joins the two constraints independently and cannot relax either.
Quota joins take the smaller remaining count, later reset and greater quota
watermarks; block joins take the later block deadline and greater block
sequence. An absent quota or block contributes no restriction and never deletes
the destination's existing constraint. Learning, changing or removing an alias
first joins the previously resolved state into the destination, even without
parsed quota headers. The source stays available to other buckets. The
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
      @mttp.Headers::of([
        ("X-RateLimit-Remaining", "2"),
        ("X-RateLimit-Reset-After", "1.5"),
      ]),
      1000L,
    ),
    Some({ remaining: 2, reset_at_unix_ms: 2500L, }),
  )
}
```

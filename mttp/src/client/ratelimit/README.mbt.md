# gaato/mttp/client/ratelimit

Client-side rate limiting that follows the quota a server announces.

`WindowLimiter` implements `@client.RateLimiter` on an injected `@rt.Clock`.
Give it a parser for the server's quota headers and pass it to
`Client::new(limiter=...)`: each request takes one unit of its bucket's quota
when it is admitted and waits while the bucket is empty, and each response
records the quota its headers report.

```mbt check
///|
test "wait for the window the server announced" {
  let clock = @sim.FakeClock::new()
  let limiter = @ratelimit.WindowLimiter::new(
    clock,
    @ratelimit.rate_limit_headers(
      remaining="X-RateLimit-Remaining",
      reset_after_seconds="X-RateLimit-Reset-After",
    ),
  )
  // The server allows no more requests for the next two seconds.
  let backend = @client.from_fn((_, _) => {
    @mttp.Response::new(
      200,
      headers=@mttp.Headers::of([
        ("X-RateLimit-Remaining", "0"),
        ("X-RateLimit-Reset-After", "2"),
      ]),
    )
  })
  let client = @client.Client::new(backend, clock, limiter~)
  @driver.run_sync(() => {
    for _ in 0..<2 {
      let reply = client.send(
        @client.get("https://api.example/items").response(@client.ignore_body()),
      )
      assert_true(reply.body is Ok(_))
    }
  })
  // The second request waited until the window reset.
  assert_eq(clock.slept(), [2000])
}
```

The client chooses the bucket from the request's `@client.rate_limit_bucket`
attribute, or `"default"`, and leaves a request out of the global window when
its `@client.global_exempt` attribute is true.

`rate_limit_headers` reads a nonnegative remaining count and a reset in
decimal seconds, either relative (`reset_after_seconds`) or as a Unix time
(`reset_unix_seconds`). The relative reset wins; a missing or malformed one
falls back to the absolute one.

`WindowLimiter::new` takes further options for APIs with more than one
window:

- `pace` maps buckets to groups whose admissions start at least
  `min_interval_ms` apart.
- `global` (`GlobalWindow`) counts the admissions of every bucket that is not
  exempt.
- `scope` says what a 429 blocks (`LimitScope`: the bucket, the global window,
  state shared by the buckets, or nothing); without it, `global_block` picks
  between the bucket and the global window. The wait comes from Retry-After
  (seconds, an HTTP date or `retry-after-ms`), or `default_retry_after_ms`
  when the header is missing or invalid, and is capped at one hour.
- `server_key` maps several buckets onto one server window, such as the
  bucket ID a server reports.
- `gate` creates a capacity-one FIFO `@rt.Gate` per pace group, so that
  waiting requests in a group are admitted in order. Without it, the
  scheduler decides who goes first.

Responses can arrive in any order. One that answers an earlier request never
refills quota that later admissions used, and no response shortens a
Retry-After wait that is in force; the
[design document](https://github.com/gaato/mttp/blob/main/design/design.md#44-client)
has the full ordering rules. The limiter's maps hold at most 4096 live
entries each, and at most 4096 requests can hold an admission at once; past
that, `acquire` raises `TransportError(kind=TooLarge(4096), phase=Pool, ..)`.

## Custom limiters

A limiter of your own implements `@client.RateLimiter`. Every `acquire` that
returns gives an `@client.Admission` built with `Admission::new(bucket,
sequence=...)`, and the Client passes that token to exactly one `release`,
with the response head when one arrived, also after a transport failure or a
cancellation; an `acquire` cancelled while waiting has none, and each retry
acquires its own token. A limiter must accept only
tokens it issued, ignore a second release of the same token, and bound the
number of tokens it keeps track of.

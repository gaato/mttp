# gaato/mttp/client/retry

Retry decisions as data. A `RetryRule` says which responses and transport
failures may be retried, for which methods, how long to wait and when to give
up; `RetryRule::decide` turns one failed attempt into `Wait(ms)` or
`Stop(reason)`. The package never sleeps, sends or reads a clock: the caller
passes the jitter sample, the current time (for an HTTP-date `Retry-After`)
and the time left in its budget, so one rule gives the same answer on every
backend.

- `statuses` lists retryable statuses (`Code`, `Range`) with the methods they
  apply to; `Idempotent` means the caller's `idempotent` fact, which
  `gaato/mttp/client` takes from the method or the `replay_safe` attribute,
  never from an `Idempotency-Key` header alone.
- `unsent_failures` retries a `TransportError` that proves nothing was sent
  (`is_unsent`) whatever the method; `sent_failures` covers the rest.
- `retry_after` reads the server's delay (`Retry-After`, or `retry-after-ms`
  first) and bounds it: stop above a limit, fall back to the backoff, or wait
  as asked. `parse_retry_after` and `retry_after_ms` are the parsers.
- `backoff` doubles `base_ms` per attempt up to `max_ms`, spread by `Jitter`.

`gaato/mttp/client` wraps a rule in `RetryPolicy` and applies it in its one
send loop; vendor presets belong to the SDK that needs them.

```mbt check
///|
test "a rate-limited POST waits as the server asks" {
  let rule : @retry.RetryRule = {
    ..@retry.RetryRule::never(),
    max_retries: 3,
    statuses: [{ statuses: [Code(429)], methods: Any, }],
    retry_after: {
      source: Header,
      cap: StopAbove(60000),
      zero_means_backoff: false,
    },
  }
  let post = @http.Request::post("https://api.example/messages").head()
  let limited = @retry.Response(
    status=429,
    headers=@http.Headers::of([("Retry-After", "2")]),
  )
  let decide = attempt => {
    rule.decide(
      limited,
      post,
      attempt~,
      random=0.5,
      idempotent=false,
      replayable=true,
    )
  }
  assert_eq(decide(0), Wait(2000))
  assert_eq(decide(3), Stop(Exhausted))
  assert_eq(@retry.parse_retry_after("1.5"), Some(1500))
}
```

# gaato/mttp_core/cache

The freshness model of [RFC 9111](https://www.rfc-editor.org/rfc/rfc9111)
section 4.2 and [RFC 5861](https://www.rfc-editor.org/rfc/rfc5861)'s
stale-while-revalidate and stale-if-error, as pure functions of a stored
response's header fields and the clock readings around it: no storage, no
I/O, so a cache, a dictionary store or a test can share them.

`CacheControl::parse` reads a Cache-Control field, request or response;
`freshness_lifetime` and `current_age` compute sections 4.2.1 and 4.2.3;
`Freshness::of` puts them together, and its methods say whether the
response is fresh, whether it may be reused without validation (not
`no-cache`), how stale it is, and whether section 4.2.4 and RFC 5861 let it
be served stale. Times are Unix milliseconds; the age is computed in
milliseconds and rounded down to whole seconds once, at the end. A
delta-seconds is capped at 2^31, as section 1.2.2 says, and sums of times
saturate instead of wrapping, so a stale window always ends. An Expires
before Date gives a lifetime below zero: the response is stale by that much.
Dates are matched case-insensitively, as section 4.2 asks of a cache.

Heuristic freshness (section 4.2.2) is left out: a response without an
explicit lifetime is never fresh here, the choice section 4.2.2 leaves to a
cache. An invalid `max-age` or `Expires` makes a response stale, as
sections 4.2.1 and 5.3 encourage.

```mbt check
///|
test "fresh for ten minutes, then served stale while it revalidates" {
  let headers = @mttp_core.Headers::of([
    ("date", "Sun, 06 Nov 1994 08:49:37 GMT"),
    ("cache-control", "max-age=600, stale-while-revalidate=30"),
  ])
  let received = 784111777000L
  let at = (seconds : Int64) => {
    @cache.Freshness::of(
      headers,
      shared=false,
      request_time_ms=received,
      response_time_ms=received,
      now_ms=received + seconds * 1000L,
    )
  }
  assert_true(at(599L).is_fresh())
  assert_true(at(620L).may_serve_while_revalidating())
  assert_false(at(631L).may_serve_while_revalidating())
}
```

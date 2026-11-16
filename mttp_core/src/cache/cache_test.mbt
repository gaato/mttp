///|
fn headers(pairs : Array[(String, String)]) -> @mttp_core.Headers {
  @mttp_core.Headers::of(pairs)
}

///|
/// 1994-11-06T08:49:37Z, the RFC 9110 example date, in milliseconds.
let t0 : Int64 = 784111777000L

///|
test "delta-seconds: digits only, capped at 2^31" {
  assert_eq(@cache.delta_seconds("0"), Some(0L))
  assert_eq(@cache.delta_seconds("3600"), Some(3600L))
  assert_eq(@cache.delta_seconds("99999999999999999999999"), Some(2147483648L))
  assert_eq(@cache.delta_seconds(""), None)
  assert_eq(@cache.delta_seconds("-1"), None)
  assert_eq(@cache.delta_seconds("1.5"), None)
}

///|
test "Cache-Control: names in any case, quoted arguments, first occurrence" {
  let cc = @cache.CacheControl::parse([
    "Max-Age=\"60\", no-cache=\"set-cookie, x\"", "max-age=10, PRIVATE",
  ])
  assert_eq(cc.max_age, Some(60L))
  assert_true(cc.no_cache)
  assert_true(cc.is_private)
  // A malformed value counts as 0, which makes the response stale.
  assert_eq(@cache.CacheControl::parse(["max-age=soon"]).max_age, Some(0L))
  assert_eq(@cache.CacheControl::parse(["max-age"]).max_age, Some(0L))
  // A quoted-string that does not close is malformed.
  assert_eq(@cache.CacheControl::parse(["max-age=\"60\\\""]).max_age, Some(0L))
  assert_eq(@cache.CacheControl::parse(["max-age=\"60\"x"]).max_age, Some(0L))
  assert_eq(@cache.CacheControl::parse(["max-age=\"6\\0\""]).max_age, Some(60L))
  let ext = @cache.CacheControl::parse([
    "stale-while-revalidate=30, stale-if-error=1200, immutable, x-unknown=1",
  ])
  assert_eq(ext.stale_while_revalidate, Some(30L))
  assert_eq(ext.stale_if_error, Some(1200L))
  assert_true(ext.immutable)
  let request = @cache.CacheControl::parse([
    "max-stale, min-fresh=5, only-if-cached",
  ])
  assert_true(request.max_stale_any)
  assert_eq(request.max_stale, None)
  assert_eq(request.min_fresh, Some(5L))
  assert_true(request.only_if_cached)
  assert_eq(@cache.CacheControl::parse(["max-stale=7"]).max_stale, Some(7L))
  let mixed = @cache.CacheControl::parse(["max-stale=0", "max-stale"])
  assert_eq((mixed.max_stale, mixed.max_stale_any), (Some(0L), false))
  let any_first = @cache.CacheControl::parse(["max-stale, max-stale=5"])
  assert_eq((any_first.max_stale, any_first.max_stale_any), (None, true))
  let all = @cache.CacheControl::parse([
    "no-store, public, must-revalidate, proxy-revalidate, s-maxage=9",
  ])
  assert_true(all.no_store && all.is_public && all.must_revalidate)
  assert_true(all.proxy_revalidate)
  assert_eq(all.s_maxage, Some(9L))
  assert_eq(@cache.CacheControl::parse([""]), @cache.CacheControl::parse([]))
  // Lines combine before they are split: a quoted-string may span them.
  assert_true(
    @cache.CacheControl::parse(["max-age=600, x=\"", "\", no-store"]).no_store,
  )
}

///|
test "freshness lifetime: s-maxage, max-age, then Expires minus Date" {
  let lifetime = (pairs : Array[(String, String)], shared : Bool) => {
    @cache.freshness_lifetime(headers(pairs), shared~, response_time_ms=t0)
  }
  let date = ("date", "Sun, 06 Nov 1994 08:49:37 GMT")
  let expires = ("expires", "Sun, 06 Nov 1994 09:49:37 GMT")
  assert_eq(
    lifetime([("cache-control", "s-maxage=5, max-age=10")], true),
    Some(5L),
  )
  assert_eq(
    lifetime([("cache-control", "s-maxage=5, max-age=10")], false),
    Some(10L),
  )
  assert_eq(
    lifetime([("cache-control", "max-age=10"), date, expires], false),
    Some(10L),
  )
  assert_eq(lifetime([date, expires], false), Some(3600L))
  // Without Date, the time the response was received.
  assert_eq(lifetime([expires], false), Some(3600L))
  // An invalid Expires, "0" above all, is already expired.
  assert_eq(lifetime([date, ("expires", "0")], false), Some(0L))
  // An Expires before Date is a lifetime below zero, stale by that much.
  assert_eq(
    lifetime([date, ("expires", "Sun, 06 Nov 1994 07:49:37 GMT")], false),
    Some(-3600L),
  )
  // Dates are matched case-insensitively.
  assert_eq(
    lifetime(
      [
        ("date", "sun, 06 nov 1994 08:49:37 gmt"),
        ("expires", "SUN, 06 NOV 1994 09:49:37 GMT"),
      ],
      false,
    ),
    Some(3600L),
  )
  assert_eq(lifetime([date], false), None)
  // A Date that does not parse is replaced by the receive time.
  assert_eq(lifetime([("date", "yesterday"), expires], false), Some(3600L))
}

///|
test "current age: the larger of the apparent and the corrected age, plus resident time" {
  let age = (
    pairs : Array[(String, String)],
    request : Int64,
    response : Int64,
    now : Int64,
  ) => {
    @cache.current_age(
      headers(pairs),
      request_time_ms=request,
      response_time_ms=response,
      now_ms=now,
    )
  }
  let date = ("date", "Sun, 06 Nov 1994 08:49:37 GMT")
  assert_eq(age([date], t0, t0, t0), 0L)
  // Received 2 s after Date, sent 1 s before receipt, 10 s ago.
  assert_eq(age([date], t0 + 1000L, t0 + 2000L, t0 + 12000L), 12L)
  // Age 100 plus the 1 s the request took.
  assert_eq(
    age([date, ("age", "100")], t0 + 1000L, t0 + 2000L, t0 + 2000L),
    101L,
  )
  // A list Age uses its first member; an invalid Age is ignored.
  assert_eq(age([date, ("age", "7, 99")], t0, t0, t0), 7L)
  assert_eq(age([date, ("age", "-3")], t0, t0, t0), 0L)
  // A server clock ahead of ours gives no negative age.
  assert_eq(age([("date", "Sun, 06 Nov 1994 09:49:37 GMT")], t0, t0, t0), 0L)
  // Clocks that run backwards give no negative age either.
  assert_eq(age([date], t0 + 5000L, t0, t0 - 9000L), 0L)
  assert_eq(age([date, ("age", "99999999999")], t0, t0, t0), 2147483648L)
  // Milliseconds add up before they are rounded down: 0.5 s + 0.6 s is 1 s.
  assert_eq(age([], 0L, 500L, 1100L), 1L)
  // A lowercase Date still counts.
  assert_eq(
    age(
      [("date", "sun, 06 nov 1994 08:49:37 gmt")],
      t0,
      t0 + 120_000L,
      t0 + 120_000L,
    ),
    120L,
  )
  // Differences between large times are kept, not erased by the bound.
  let big = 2305843009213693952L
  assert_eq(age([], big + 1000L, big + 2000L, big + 102000L), 101L)
  // Arithmetic saturates rather than wraps.
  assert_true(
    age(
      [],
      -9223372036854775807L - 1L,
      9223372036854775807L,
      9223372036854775807L,
    ) >
    0L,
  )
}

///|
test "fresh, stale, and when a stale response may still be served" {
  let view = (cc : String, now_s : Int64, shared : Bool) => {
    @cache.Freshness::of(
      headers([("date", "Sun, 06 Nov 1994 08:49:37 GMT"), ("cache-control", cc)]),
      shared~,
      request_time_ms=t0,
      response_time_ms=t0,
      now_ms=t0 + now_s * 1000L,
    )
  }
  let f = view(
    "max-age=600, stale-while-revalidate=30, stale-if-error=1200", 599L, false,
  )
  assert_true(f.is_fresh())
  assert_eq(f.staleness(), 0L)
  assert_false(f.may_serve_while_revalidating())
  assert_false(f.may_serve_on_error())
  let swr = view("max-age=600, stale-while-revalidate=30", 630L, false)
  assert_false(swr.is_fresh())
  assert_eq(swr.staleness(), 30L)
  assert_true(swr.may_serve_while_revalidating())
  assert_false(
    view("max-age=600, stale-while-revalidate=30", 631L, false).may_serve_while_revalidating(),
  )
  let sie = view("max-age=600, stale-if-error=1200", 900L, false)
  assert_true(sie.may_serve_on_error())
  assert_false(
    view("max-age=600, stale-if-error=1200", 1801L, false).may_serve_on_error(),
  )
  // The request's stale-if-error takes the place of the response's.
  let narrow = @cache.CacheControl::parse(["stale-if-error=60"])
  assert_false(sie.may_serve_on_error(request=narrow))
  assert_true(
    view("max-age=600", 900L, false).may_serve_on_error(
      request=@cache.CacheControl::parse(["stale-if-error=600"]),
    ),
  )
  // Directives that forbid serving stale.
  assert_false(
    view("max-age=1, must-revalidate, stale-while-revalidate=99", 5L, false).may_serve_while_revalidating(),
  )
  assert_false(
    view("max-age=1, no-cache, stale-if-error=99", 5L, false).may_serve_on_error(),
  )
  assert_true(
    view("max-age=1, proxy-revalidate, stale-while-revalidate=99", 5L, false).may_serve_while_revalidating(),
  )
  assert_false(
    view("max-age=1, proxy-revalidate, stale-while-revalidate=99", 5L, true).may_serve_while_revalidating(),
  )
  assert_false(
    view("s-maxage=1, stale-while-revalidate=99", 5L, true).may_serve_while_revalidating(),
  )
  // An Expires an hour before Date leaves no stale-while-revalidate window.
  let past = @cache.Freshness::of(
    headers([
      ("date", "Sun, 06 Nov 1994 08:49:37 GMT"),
      ("expires", "Sun, 06 Nov 1994 07:49:37 GMT"),
      ("cache-control", "stale-while-revalidate=60"),
    ]),
    shared=false,
    request_time_ms=t0,
    response_time_ms=t0,
    now_ms=t0,
  )
  assert_eq(past.staleness(), 3600L)
  assert_false(past.may_serve_while_revalidating())
  // An Expires far in the past is stale by all of it, not by a capped amount.
  let ancient = @cache.Freshness::of(
    headers([
      ("date", "Sun, 06 Nov 1994 08:49:37 GMT"),
      ("expires", "Mon, 01 Jan 1900 00:00:00 GMT"),
      ("cache-control", "stale-while-revalidate=2147483648"),
    ]),
    shared=false,
    request_time_ms=t0,
    response_time_ms=t0,
    now_ms=t0,
  )
  assert_eq(ancient.staleness(), 2993100577L)
  assert_false(ancient.may_serve_while_revalidating())
  // A window past the largest lifetime still ends.
  let huge = @cache.Freshness::of(
    headers([("cache-control", "max-age=2147483648, stale-while-revalidate=1")]),
    shared=false,
    request_time_ms=0L,
    response_time_ms=0L,
    now_ms=2147483748000L,
  )
  assert_false(huge.may_serve_while_revalidating())
  // no-cache: fresh, but not reusable without validation.
  let validate = view("max-age=600, no-cache", 1L, false)
  assert_true(validate.is_fresh())
  assert_false(validate.reusable())
  assert_true(view("max-age=600", 1L, false).reusable())
  // Without an explicit lifetime nothing is fresh, and nothing is served stale.
  let none = view("stale-while-revalidate=99", 0L, false)
  assert_eq(none.lifetime, None)
  assert_false(none.is_fresh())
  assert_false(none.may_serve_while_revalidating())
  assert_false(
    none.may_serve_on_error(
      request=@cache.CacheControl::parse(["stale-if-error=99"]),
    ),
  )
}

///|
test "storable: not no-store, and private only in a private cache" {
  let view = (cc : String, shared : Bool) => {
    @cache.Freshness::of(
      headers([("cache-control", cc)]),
      shared~,
      request_time_ms=t0,
      response_time_ms=t0,
      now_ms=t0,
    )
  }
  assert_true(view("max-age=60", false).storable())
  assert_false(view("max-age=60, no-store", false).storable())
  assert_true(view("max-age=60, private", false).storable())
  assert_false(view("max-age=60, private", true).storable())
}

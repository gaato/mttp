///|
test "heuristic lifetime is bounded, status-limited and explicit lifetime wins" {
  let h = @mttp_core.Headers::of([
    ("date", "Sun, 06 Nov 1994 08:49:37 GMT"),
    ("last-modified", "Sun, 06 Nov 1994 08:39:37 GMT"),
  ])
  assert_eq(@cache.heuristic_lifetime(h, 200, percent=10), Some(60L))
  assert_eq(@cache.heuristic_lifetime(h, 200, percent=200), Some(600L))
  assert_eq(@cache.heuristic_lifetime(h, 302, percent=10), None)
  assert_eq(@cache.heuristic_lifetime(h, 200, percent=0), None)
  assert_eq(
    @cache.heuristic_lifetime(h.set("expires", "bad"), 200, percent=10),
    None,
  )
  assert_eq(
    @cache.heuristic_lifetime(
      h.set("cache-control", "max-age=0"),
      200,
      percent=10,
    ),
    None,
  )
  assert_eq(
    @cache.heuristic_lifetime(h.set("last-modified", "bad"), 200, percent=10),
    None,
  )
  assert_eq(
    @cache.heuristic_lifetime(
      h.set("last-modified", "Sun, 06 Nov 1994 08:59:37 GMT"),
      200,
      percent=10,
    ),
    None,
  )
  assert_eq(
    @cache.heuristic_lifetime(@mttp_core.Headers::empty(), 200, percent=10),
    None,
  )
}

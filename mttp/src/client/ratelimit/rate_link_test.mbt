///|
test "rate_limit_headers parses relative and absolute decimal seconds" {
  let both = @ratelimit.rate_limit_headers(
    remaining="x-remaining",
    reset_after_seconds="x-reset-after",
    reset_unix_seconds="x-reset",
  )
  let mut headers = @model.Headers::of([
    ("X-Remaining", " 2 "),
    ("X-Reset-After", "1.2349"),
    ("X-Reset", "99.5"),
  ])
  assert_eq(
    both(headers, 1000L),
    Some({ remaining: 2, reset_at_unix_ms: 2234L, }),
  )
  headers = headers.set("x-reset-after", "bad")
  assert_eq(
    both(headers, 1000L),
    Some({ remaining: 2, reset_at_unix_ms: 99500L, }),
  )
  headers = headers.set("x-remaining", "-1")
  assert_eq(both(headers, 1000L), None)
  headers = headers.set("x-remaining", "2147483648")
  assert_eq(both(headers, 1000L), None)
  headers = headers.set("x-remaining", "2")
  headers = headers.set("x-reset", "6m0s")
  assert_eq(both(headers, 1000L), None)
  let absolute = @ratelimit.rate_limit_headers(
    remaining="remaining",
    reset_unix_seconds="reset",
  )
  assert_eq(
    absolute(
      @model.Headers::of([("remaining", "0"), ("reset", "123.4567")]),
      999L,
    ),
    Some({ remaining: 0, reset_at_unix_ms: 123456L, }),
  )
}

///|
test "rate header parsers reject missing resets empty counts and incomplete decimals" {
  let relative = @ratelimit.rate_limit_headers(
    remaining="remaining",
    reset_after_seconds="reset",
  )
  let absolute = @ratelimit.rate_limit_headers(
    remaining="remaining",
    reset_unix_seconds="reset",
  )
  for parse in [relative, absolute] {
    assert_eq(parse(@model.Headers::of([("remaining", "1")]), 0L), None)
    for value in ["", ".", ".1", "1."] {
      assert_eq(
        parse(@model.Headers::of([("remaining", "1"), ("reset", value)]), 0L),
        None,
      )
    }
    assert_eq(
      parse(@model.Headers::of([("remaining", " "), ("reset", "1")]), 0L),
      None,
    )
  }
}

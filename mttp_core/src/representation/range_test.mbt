///|
test "RFC byte range examples suffix open-ended unsatisfiable malformed and overflow" {
  let validators = @representation.Validators::new(
    etag="\"v1\"",
    last_modified_ms=100999L,
  )
  for
    (value, length, expected) in [
      ("bytes=0-499", 10000L, @representation.Partial(start=0L, end=499L)),
      ("bytes=500-999", 10000L, Partial(start=500L, end=999L)),
      ("bytes=-500", 10000L, Partial(start=9500L, end=9999L)),
      ("bytes=9500-", 10000L, Partial(start=9500L, end=9999L)),
      ("bytes=0-99999", 10L, Partial(start=0L, end=9L)),
      ("bytes=-500", 10L, Partial(start=0L, end=9L)),
      ("bytes=10-", 10L, Unsatisfiable),
      ("bytes=0-", 0L, Unsatisfiable),
      ("bytes=-1", 0L, Unsatisfiable),
      ("bytes=-0", 10L, Unsatisfiable),
      ("bytes=2-1", 10L, Full),
      ("bytes=0-1,3-4", 10L, Full),
      ("items=0-1", 10L, Full),
      ("bytes=9223372036854775808-", 10L, Full),
      ("bytes=0-9223372036854775808", 10L, Full),
      ("bytes=-9223372036854775808", 10L, Full),
      ("bytes=0-9223372036854775807", 10L, Partial(start=0L, end=9L)),
      ("bytes=-9223372036854775807", 10L, Partial(start=0L, end=9L)),
      ("bytes=", 10L, Full),
      ("bytes=-", 10L, Full),
      ("bytes=1-x", 10L, Full),
      ("bytes=1-2-3", 10L, Full),
    ] {
    assert_eq(
      @representation.choose_range(head([("range", value)]), length, validators),
      expected,
      msg=value,
    )
  }
  assert_eq(
    @representation.choose_range(
      head([("range", "bytes=0-1")], meth=Head),
      10L,
      validators,
    ),
    @representation.Full,
  )
  for
    (value, expected) in [
      ("\"v1\"", @representation.Partial(start=0L, end=1L)),
      ("W/\"v1\"", Full),
      ("\"other\"", Full),
      (@mttp_core.format_http_date(100000L), Partial(start=0L, end=1L)),
      (@mttp_core.format_http_date(99000L), Full),
      (@mttp_core.format_http_date(101000L), Full),
      ("invalid", Full),
    ] {
    assert_eq(
      @representation.choose_range(
        head([("range", "bytes=0-1"), ("if-range", value)]),
        10L,
        validators,
      ),
      expected,
    )
  }
  assert_eq(
    @representation.content_range(0L, 499L, 10000L),
    "bytes 0-499/10000",
  )
  let refused = @representation.range_not_satisfiable(10L)
  assert_eq(refused.status, 416)
  assert_eq(refused.headers.get("content-range"), Some("bytes */10"))
}

///|
test "Range bounds accept 1 KiB ignore 1 KiB plus one and 101 ranges" {
  let validators = @representation.Validators::new()
  for n in [1024, 1025] {
    let value = "bytes=0-1" + String::make(n - 9, ' ')
    assert_eq(
      @representation.choose_range(head([("range", value)]), 10L, validators),
      if n == 1024 {
        @representation.Partial(start=0L, end=1L)
      } else {
        @representation.Full
      },
    )
  }
  let unicode = "bytes=0-1" + String::make(510, 'é')
  assert_eq(
    @representation.choose_range(head([("range", unicode)]), 10L, validators),
    @representation.Full,
  )
  for n in [100, 101] {
    let value = "bytes=" + Array::make(n, "0-1").join(",")
    assert_eq(
      @representation.choose_range(head([("range", value)]), 10L, validators),
      @representation.Full,
    )
  }
  assert_eq(
    @representation.choose_range(
      head([("range", "bytes=0-1"), ("range", "bytes=2-3")]),
      10L,
      validators,
    ),
    @representation.Full,
  )
}

///|
test "byte range units are case insensitive without weakening range syntax" {
  let validators = @representation.Validators::new()
  for unit in ["bytes", "Bytes", "BYTES", "bYtEs"] {
    assert_eq(
      @representation.choose_range(
        head([("range", unit + "=0-1")]),
        10L,
        validators,
      ),
      @representation.Partial(start=0L, end=1L),
    )
    assert_eq(
      @representation.choose_range(
        head([("range", unit + "=0-1,3-4")]),
        10L,
        validators,
      ),
      @representation.Full,
    )
    assert_eq(
      @representation.choose_range(
        head([("range", unit + "=1-x")]),
        10L,
        validators,
      ),
      @representation.Full,
    )
  }
  assert_eq(
    @representation.choose_range(
      head([("range", "BytesX=0-1")]),
      10L,
      validators,
    ),
    @representation.Full,
  )
}

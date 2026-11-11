///|
test "decimal seconds validate completely and saturate without rounding" {
  for
    (value, expected) in [
      ("0", Some(0)),
      ("12", Some(12000)),
      ("1.5", Some(1500)),
      ("1.2349", Some(1234)),
      ("0.0009999", Some(0)),
      ("0001.02", Some(1020)),
      (" \t1.25\r\n", Some(1250)),
      ("2147483.647", Some(2147483647)),
      ("2147483.648", Some(2147483647)),
      ("99999999999999999999999999999.99999", Some(2147483647)),
      ("-1", None),
      ("-0.5", None),
      ("+1", None),
      ("1e3", None),
      ("", None),
      (" \t", None),
      (".5", None),
      ("1.", None),
      ("1.2.3", None),
      ("1 2", None),
      ("NaN", None),
      ("Infinity", None),
      ("garbage", None),
      ("999999999999999999999999x", None),
      ("１", None),
    ] {
    assert_eq(@retry.parse_retry_after(value), expected, msg=value)
  }
}

///|
test "header precedence units duplicates and ASCII case" {
  let mut headers = @mttp.Headers::empty()
  assert_eq(@retry.retry_after_ms(headers), None)
  headers = headers.set("ReTrY-AfTeR", "1.25")
  assert_eq(@retry.retry_after_ms(headers), Some(1250))
  for
    (value, expected) in [
      ("12", Some(12)),
      (" 12.9999\t", Some(12)),
      ("0.999", Some(0)),
      ("2147483647", Some(2147483647)),
      ("999999999999999999999.5", Some(2147483647)),
      ("-1", Some(1250)), // falls back to retry-after: 1.25
      ("garbage", Some(1250)), // falls back to retry-after: 1.25
      ("", Some(1250)), // falls back to retry-after: 1.25
      (".5", Some(1250)), // falls back to retry-after: 1.25
      ("1.", Some(1250)), // falls back to retry-after: 1.25
      ("1e3", Some(1250)), // falls back to retry-after: 1.25
      ("99999999999999x", Some(1250)), // falls back to retry-after: 1.25
    ] {
    headers = headers.set("RETRY-after-MS", value)
    assert_eq(@retry.retry_after_ms(headers), expected, msg=value)
  }
  headers = headers.set("retry-after-ms", "8")
  headers = headers.add("Retry-After-Ms", "99")
  assert_eq(@retry.retry_after_ms(headers), Some(8))
  headers = headers.remove("retry-after")
  headers = headers.set("retry-after-ms", "garbage")
  assert_eq(@retry.retry_after_ms(headers), None)
  headers = headers.remove("retry-after-ms")
  headers = headers.set("retry-after", "Thu, 01 Jan 1970 00:00:01 GMT")
  assert_eq(@retry.retry_after_ms(headers), None)
  assert_eq(@retry.retry_after_ms(headers, now_unix_ms=0L), Some(1000))
}

///|
test "IMF fixdate epoch clock extremes and truncation independent of local timezone" {
  let date = "Sun, 06 Nov 1994 08:49:37 GMT"
  assert_eq(@retry.parse_retry_after(date), None)
  // Neither seconds nor an HTTP date, even with a clock.
  assert_eq(@retry.parse_retry_after("06 Nov 1994", now_unix_ms=0L), None)
  assert_eq(@retry.parse_retry_after("soon", now_unix_ms=0L), None)
  assert_eq(
    @retry.parse_retry_after(date, now_unix_ms=784111776123L),
    Some(877),
  )
  assert_eq(@retry.parse_retry_after(date, now_unix_ms=784111777000L), Some(0))
  assert_eq(@retry.parse_retry_after(date, now_unix_ms=784111778000L), Some(0))
  assert_eq(@retry.parse_retry_after(date, now_unix_ms=0L), Some(2147483647))
  assert_eq(
    @retry.parse_retry_after(date, now_unix_ms=-9223372036854775808L),
    Some(2147483647),
  )
  assert_eq(
    @retry.parse_retry_after(date, now_unix_ms=9223372036854775807L),
    Some(0),
  )
  assert_eq(
    @retry.parse_retry_after(
      " \tThu, 01 Jan 1970 00:00:01 GMT\r\n",
      now_unix_ms=0L,
    ),
    Some(1000),
  )
  assert_eq(
    @retry.parse_retry_after(
      "Wed, 31 Dec 1969 23:59:59 GMT",
      now_unix_ms=-2000L,
    ),
    Some(1000),
  )
  assert_eq(
    @retry.parse_retry_after(
      "Thu, 01 Jan 1970 00:00:00 GMT",
      now_unix_ms=-2147483647L,
    ),
    Some(2147483647),
  )
}

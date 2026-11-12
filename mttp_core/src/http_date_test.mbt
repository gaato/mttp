///|
test "format_http_date writes IMF-fixdate that parses back to the second" {
  for
    (epoch, date) in [
      (0L, "Thu, 01 Jan 1970 00:00:00 GMT"),
      (784111777000L, "Sun, 06 Nov 1994 08:49:37 GMT"),
      (951782400000L, "Tue, 29 Feb 2000 00:00:00 GMT"),
      (1709164800000L, "Thu, 29 Feb 2024 00:00:00 GMT"),
      (-2203891200000L, "Thu, 01 Mar 1900 00:00:00 GMT"),
      (-62135596800000L, "Mon, 01 Jan 0001 00:00:00 GMT"),
      (253402300799000L, "Fri, 31 Dec 9999 23:59:59 GMT"),
    ] {
    assert_eq(@mttp_core.format_http_date(epoch), date)
    assert_eq(@mttp_core.parse_http_date(date, now_unix_ms=0L), Some(epoch))
  }
  // Milliseconds round toward the past, before and after the epoch.
  assert_eq(
    @mttp_core.format_http_date(784111777999L),
    "Sun, 06 Nov 1994 08:49:37 GMT",
  )
  assert_eq(@mttp_core.format_http_date(-1L), "Wed, 31 Dec 1969 23:59:59 GMT")
  assert_eq(
    @mttp_core.format_http_date(-1000L),
    "Wed, 31 Dec 1969 23:59:59 GMT",
  )
  assert_eq(
    @mttp_core.format_http_date(-1001L),
    "Wed, 31 Dec 1969 23:59:58 GMT",
  )
}

///|
test "format_http_date clamps to the years the format can carry" {
  for
    (epoch, date) in [
      (-62135596800001L, "Mon, 01 Jan 0001 00:00:00 GMT"),
      (-9223372036854775808L, "Mon, 01 Jan 0001 00:00:00 GMT"),
      (253402300800000L, "Fri, 31 Dec 9999 23:59:59 GMT"),
      (9223372036854775807L, "Fri, 31 Dec 9999 23:59:59 GMT"),
    ] {
    assert_eq(@mttp_core.format_http_date(epoch), date)
  }
}

///|
test "IMF-fixdate is read in UTC" {
  assert_eq(
    @mttp_core.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT", now_unix_ms=0L),
    Some(784111777000L),
  )
  assert_eq(
    @mttp_core.parse_http_date("Thu, 01 Jan 1970 00:00:00 GMT", now_unix_ms=0L),
    Some(0L),
  )
  // The clock places only rfc850-date's year; any clock reads IMF-fixdate.
  for now in [-9223372036854775808L, -1L, 0L, 9223372036854775807L] {
    assert_eq(
      @mttp_core.parse_http_date(
        "Sun, 06 Nov 1994 08:49:37 GMT",
        now_unix_ms=now,
      ),
      Some(784111777000L),
    )
  }
}

///|
test "Gregorian leap years and month boundaries" {
  // Known UTC epoch milliseconds, exercising March-based year/era boundaries.
  for
    (date, epoch) in [
      ("Mon, 01 Jan 0001 00:00:00 GMT", -62135596800000L),
      ("Thu, 01 Mar 1900 00:00:00 GMT", -2203891200000L),
      ("Tue, 29 Feb 2000 00:00:00 GMT", 951782400000L),
      ("Wed, 01 Mar 2000 00:00:00 GMT", 951868800000L),
      ("Thu, 29 Feb 2024 00:00:00 GMT", 1709164800000L),
      ("Fri, 01 Mar 2024 00:00:00 GMT", 1709251200000L),
      ("Mon, 01 Apr 2024 00:00:00 GMT", 1711929600000L),
      ("Wed, 01 May 2024 00:00:00 GMT", 1714521600000L),
      ("Sat, 01 Jun 2024 00:00:00 GMT", 1717200000000L),
      ("Mon, 01 Jul 2024 00:00:00 GMT", 1719792000000L),
      ("Thu, 01 Aug 2024 00:00:00 GMT", 1722470400000L),
      ("Sun, 01 Sep 2024 00:00:00 GMT", 1725148800000L),
      ("Tue, 01 Oct 2024 00:00:00 GMT", 1727740800000L),
      ("Fri, 01 Nov 2024 00:00:00 GMT", 1730419200000L),
      ("Sun, 01 Dec 2024 00:00:00 GMT", 1733011200000L),
      ("Wed, 01 Jan 2025 00:00:00 GMT", 1735689600000L),
      ("Mon, 01 Mar 2100 00:00:00 GMT", 4107542400000L),
    ] {
    assert_eq(
      @mttp_core.parse_http_date(date, now_unix_ms=0L),
      Some(epoch),
      msg=date,
    )
  }
  // Leap-second syntax is accepted as the following Unix second.
  assert_eq(
    @mttp_core.parse_http_date("Sat, 31 Dec 2016 23:59:60 GMT", now_unix_ms=0L),
    Some(1483228800000L),
  )
}

///|
test "the obsolete rfc850-date and asctime-date are accepted" {
  // RFC 9110 §5.6.7: a recipient MUST accept all three forms.
  let now = 784111777000L
  for
    date in [
      "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994", "Sun Nov 06 08:49:37 1994",
    ] {
    assert_eq(
      @mttp_core.parse_http_date(date, now_unix_ms=now),
      Some(784111777000L),
      msg=date,
    )
  }
}

///|
test "a two-digit year more than 50 years ahead is from the century before" {
  // 2026-10-21: 70 is 2070 and 76 is 2076, both ahead; 77 is 1977. Each
  // weekday holds only for the year the rule picks.
  let now = 1792540800000L
  for
    (date, expected) in [
      ("Wednesday, 01-Jan-70 00:00:00 GMT", Some(3155760000000L)),
      ("Wednesday, 21-Oct-76 00:00:00 GMT", Some(3370464000000L)),
      ("Saturday, 01-Jan-77 00:00:00 GMT", Some(220924800000L)),
      ("Thursday, 01-Jan-70 00:00:00 GMT", None),
      ("Friday, 01-Jan-77 00:00:00 GMT", None),
    ] {
    assert_eq(
      @mttp_core.parse_http_date(date, now_unix_ms=now),
      expected,
      msg=date,
    )
  }
  // A clock before 1970 is in 1969, so 68 is 1968, whose 1 January was a
  // Monday.
  assert_eq(
    @mttp_core.parse_http_date(
      "Monday, 01-Jan-68 00:00:00 GMT",
      now_unix_ms=-1L,
    ),
    Some(-63158400000L),
  )
  assert_eq(
    @mttp_core.parse_http_date(
      "Tuesday, 08-Nov-94 08:49:37 GMT",
      now_unix_ms=784111777000L,
    ),
    Some(784111777000L + 2L * 86400000L),
  )
}

///|
test "malformed obsolete dates are rejected" {
  for
    date in [
      "sunday, 06-Nov-94 08:49:37 GMT", "Sun, 06-Nov-94 08:49:37 GMT", "Sunday, 06-Nov-1994 08:49:37 GMT",
      "Sunday, 06 Nov 94 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 UTC", "Monday, 06-Nov-94 08:49:37 GMT",
      "Sunday, 06-nov-94 08:49:37 GMT", "Sunday,06-Nov-94 08:49:37 GMT", "Sun Nov 6 08:49:37 1994",
      "Sun Nov  6 08:49:37 1994 GMT", "sun Nov  6 08:49:37 1994", "Sun Nov  6 08:49:37 94",
      "Mon Nov  6 08:49:37 1994", "Sun Nov 6  08:49:37 1994", "Sun Nov  6 08:49 37 1994",
    ] {
    assert_eq(@mttp_core.parse_http_date(date, now_unix_ms=0L), None, msg=date)
  }
}

///|
test "invalid dates and inconsistent weekday are rejected" {
  for
    date in [
      "Sun, 06 Nov 1994 08:49:37 UTC", "sun, 06 Nov 1994 08:49:37 GMT", "Mon, 06 Nov 1994 08:49:37 GMT",
      "Sun, 06 Xxx 1994 08:49:37 GMT", "Sun, 06 nov 1994 08:49:37 GMT", "Thu, 29 Feb 1900 00:00:00 GMT",
      "Wed, 29 Feb 2023 00:00:00 GMT", "Mon, 31 Apr 2024 00:00:00 GMT", "Thu, 00 Feb 2024 00:00:00 GMT",
      "Thu, 32 Feb 2024 00:00:00 GMT", "Thu, 29 Feb 2024 24:00:00 GMT", "Thu, 29 Feb 2024 00:60:00 GMT",
      "Thu, 29 Feb 2024 00:00:61 GMT", "Thu, 29 Feb 0000 00:00:00 GMT", "Thu, 2x Feb 2024 00:00:00 GMT",
      "Thu, 29 Feb 2024 00-00:00 GMT", "Thu, 29 Feb 2024 00:00:00 GMT extra", " Sun, 06 Nov 1994 08:49:37 GMT",
      "🌙🌙🌙🌙🌙🌙🌙🌙🌙🌙🌙🌙🌙abc",
    ] {
    assert_eq(@mttp_core.parse_http_date(date, now_unix_ms=0L), None, msg=date)
  }
}

///|
test "the fifty-year cutoff compares the whole date, not the year" {
  // RFC 9110 §5.6.7: a date more than 50 years ahead of the clock is from
  // the century before. The clock is 2026-10-21T00:00:00Z, so the cutoff is
  // 2076-10-21T00:00:00Z, itself still allowed.
  let now = 1792540800000L
  for
    (date, expected) in [
      // Late in 2076 is past the cutoff: 1976. The weekday holds only then.
      ("Friday, 31-Dec-76 00:00:00 GMT", Some(220838400000L)),
      ("Thursday, 31-Dec-76 00:00:00 GMT", None),
      // The day after the cutoff: 1976-10-22, a Friday.
      ("Friday, 22-Oct-76 00:00:00 GMT", Some(214790400000L)),
      ("Thursday, 22-Oct-76 00:00:00 GMT", None),
      // One second past the cutoff is 1976 as well.
      ("Thursday, 21-Oct-76 00:00:01 GMT", Some(214704001000L)),
      // The cutoff itself: 2076-10-21, a Wednesday.
      ("Wednesday, 21-Oct-76 00:00:00 GMT", Some(3370464000000L)),
      ("Thursday, 21-Oct-76 00:00:00 GMT", None),
    ] {
    assert_eq(
      @mttp_core.parse_http_date(date, now_unix_ms=now),
      expected,
      msg=date,
    )
  }
}

///|
test "a two-digit year may name the next century" {
  // The clock is 2090-01-01T00:00:00Z: `10` is 2110, 20 years ahead, not
  // 2010; `89` is 2089, not 2189; `40` is 2140 exactly at the cutoff, and
  // 2040 one second past it.
  let now = 3786912000000L
  for
    (date, expected) in [
      ("Wednesday, 01-Jan-10 00:00:00 GMT", Some(4417977600000L)),
      ("Friday, 01-Jan-10 00:00:00 GMT", None),
      ("Saturday, 01-Jan-89 00:00:00 GMT", Some(3755376000000L)),
      ("Friday, 01-Jan-40 00:00:00 GMT", Some(5364662400000L)),
      ("Sunday, 01-Jan-40 00:00:00 GMT", None),
      ("Sunday, 01-Jan-40 00:00:01 GMT", Some(2208988801000L)),
      ("Friday, 01-Jan-40 00:00:01 GMT", None),
    ] {
    assert_eq(
      @mttp_core.parse_http_date(date, now_unix_ms=now),
      expected,
      msg=date,
    )
  }
}

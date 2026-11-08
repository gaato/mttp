///|
/// Builds a `WindowLimiter` parser for the conventional remaining and reset
/// response headers. `remaining` names the header with the requests left in
/// the window (a non-negative decimal integer). The reset comes from
/// `reset_after_seconds`, seconds from now (Discord's
/// `X-RateLimit-Reset-After`), or else from `reset_unix_seconds`, a Unix
/// time in seconds (GitHub's `X-RateLimit-Reset`); both accept a decimal
/// fraction, read to the millisecond. A response without a valid count and
/// reset records nothing. Header names ignore ASCII case.
///
/// ```mbt check
/// test {
///   let github = @ratelimit.rate_limit_headers(
///     remaining="x-ratelimit-remaining",
///     reset_unix_seconds="x-ratelimit-reset",
///   )
///   let headers = @http.Headers::of([
///     ("X-RateLimit-Remaining", "4999"),
///     ("X-RateLimit-Reset", "1700000060"),
///   ])
///   assert_eq(
///     github(headers, 1_700_000_000_000L),
///     Some({ remaining: 4999, reset_at_unix_ms: 1_700_000_060_000L, }),
///   )
/// }
/// ```
pub fn rate_limit_headers(
  remaining~ : String,
  reset_after_seconds? : String,
  reset_unix_seconds? : String,
) -> (@http.Headers, Int64) -> RateLimitState? {
  (headers, now) => {
    guard headers.get(remaining) is Some(raw_remaining) else { return None }
    guard parse_nonnegative_int(raw_remaining) is Some(left) else {
      return None
    }
    let reset = match reset_after_seconds {
      Some(name) =>
        match headers.get(name) {
          Some(value) =>
            decimal_seconds_ms(value).map(ms => saturating_add_i64(now, ms))
          None => None
        }
      None => None
    }
    let reset = match reset {
      Some(value) => Some(value)
      None =>
        match reset_unix_seconds {
          Some(name) =>
            match headers.get(name) {
              Some(value) => decimal_seconds_ms(value)
              None => None
            }
          None => None
        }
    }
    reset.map(reset_at_unix_ms => { remaining: left, reset_at_unix_ms, })
  }
}

///|
fn parse_nonnegative_int(value : String) -> Int32? {
  let value = value.trim()
  if value.is_empty() {
    return None
  }
  let mut result = 0
  for c in value {
    guard c >= '0' && c <= '9' else { return None }
    let digit = c.to_int() - 48
    if result > (2147483647 - digit) / 10 {
      return None
    }
    result = result * 10 + digit
  }
  Some(result)
}

///|
fn decimal_seconds_ms(value : String) -> Int64? {
  let value = value.trim()
  let mut whole = 0L
  let mut fraction = 0L
  let mut weight = 100L
  let mut dot = false
  let mut before = 0
  let mut after = 0
  for c in value {
    if c == '.' && !dot {
      dot = true
    } else if c >= '0' && c <= '9' {
      let digit = (c.to_int() - 48).to_int64()
      if dot {
        after += 1
        if weight > 0L {
          fraction += digit * weight
          weight /= 10L
        }
      } else {
        before += 1
        whole = if whole > (9223372036854775807L - digit) / 10L {
          9223372036854775807L
        } else {
          whole * 10L + digit
        }
      }
    } else {
      return None
    }
  }
  if before == 0 || (dot && after == 0) {
    return None
  }
  if whole > (9223372036854775807L - fraction) / 1000L {
    Some(9223372036854775807L)
  } else {
    Some(whole * 1000L + fraction)
  }
}

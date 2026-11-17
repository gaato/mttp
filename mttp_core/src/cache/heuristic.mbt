///|
/// RFC 9111 section 4.2.2: a fraction of Date minus Last-Modified, in
/// seconds, only for heuristically cacheable statuses and without explicit
/// expiration. The caller excludes query URLs. Percent is clamped to 0..100;
/// missing/invalid dates or a future modification give no heuristic.
pub fn heuristic_lifetime(
  headers : @mttp_core.Headers,
  status : Int32,
  percent~ : Int32,
) -> Int64? {
  if percent <= 0 ||
    !heuristic_status(status) ||
    headers.contains("expires") ||
    CacheControl::parse(headers.get_all("cache-control")).max_age is Some(_) {
    return None
  }
  guard headers.get("date") is Some(date) &&
    headers.get("last-modified") is Some(modified) else {
    return None
  }
  guard http_date(date, 0L) is Some(now) &&
    http_date(modified, now) is Some(then) &&
    then <= now else {
    return None
  }
  Some(sub_ms(now, then) / 1000L * percent.min(100).to_int64() / 100L)
}

///|
fn heuristic_status(status : Int32) -> Bool {
  match status {
    200 | 203 | 204 | 206 | 300 | 301 | 308 | 404 | 405 | 410 | 414 | 501 =>
      true
    _ => false
  }
}

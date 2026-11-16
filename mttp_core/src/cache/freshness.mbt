// Freshness and age (RFC 9111 section 4.2) and serving stale responses
// (section 4.2.4, RFC 5861), as pure functions of a stored response's
// header fields and the clock readings around it. Times are Unix
// milliseconds; ages and lifetimes are whole seconds.

///|
/// What section 4.2 needs of a stored response: its directives, its
/// explicit freshness lifetime and its current age.
#derive(Eq, Debug)
pub(all) struct Freshness {
  cache_control : CacheControl
  /// The explicit freshness lifetime in seconds (section 4.2.1), or None
  /// when the response has none. Heuristic freshness (section 4.2.2) is not
  /// computed: a response without an explicit lifetime is not fresh here.
  lifetime : Int64?
  /// The current age in seconds (section 4.2.3).
  age : Int64
  /// Whether this is a shared cache's view (s-maxage, proxy-revalidate).
  shared : Bool
}

///|
/// Compares two views.
pub extend Freshness with Eq::{equal, not_equal}

///|
/// Debug representation of a view.
pub extend Freshness with @debug.Debug::{to_repr}

///|
/// The bound saturating arithmetic stops at, in milliseconds: far past any
/// real time, far from overflowing.
const LIMIT_MS : Int64 = 2305843009213693952L

///|
fn clamp_ms(v : Int64) -> Int64 {
  if v > LIMIT_MS {
    LIMIT_MS
  } else if v < -LIMIT_MS {
    -LIMIT_MS
  } else {
    v
  }
}

///|
/// `a - b` without wrapping: a result past the bound is the bound, which
/// section 1.2.2 asks of an overflow.
fn sub_ms(a : Int64, b : Int64) -> Int64 {
  // a - b overflows exactly when the operands' signs differ and the
  // result's sign is not a's.
  let d = a - b
  if (a ^ b) < 0L && (a ^ d) < 0L {
    if a < 0L {
      -LIMIT_MS
    } else {
      LIMIT_MS
    }
  } else {
    clamp_ms(d)
  }
}

///|
fn add_ms(a : Int64, b : Int64) -> Int64 {
  let s = a + b
  if (a ^ b) >= 0L && (a ^ s) < 0L {
    if a < 0L {
      -LIMIT_MS
    } else {
      LIMIT_MS
    }
  } else {
    clamp_ms(s)
  }
}

///|
/// Milliseconds as whole seconds, rounded down (toward the past).
fn floor_seconds(ms : Int64) -> Int64 {
  if ms >= 0L {
    ms / 1000L
  } else {
    -((-ms + 999L) / 1000L)
  }
}

///|
/// An HTTP-date matched case-insensitively, as section 4.2 has a cache do:
/// day and month names and GMT are put in the case RFC 9110 writes them.
fn http_date(text : String, now_ms : Int64) -> Int64? {
  let out = StringBuilder()
  let mut word_start = true
  for c in text {
    if c.is_ascii_alphabetic() {
      out.write_char(
        if word_start {
          c.to_ascii_uppercase()
        } else {
          c.to_ascii_lowercase()
        },
      )
      word_start = false
    } else {
      out.write_char(c)
      word_start = true
    }
  }
  let normalized = out.to_string().replace_all(old="Gmt", new="GMT")
  @mttp_core.parse_http_date(normalized, now_unix_ms=now_ms)
}

///|
/// The Date field's time, or `response_time_ms` when it is absent or
/// invalid, as RFC 9110 section 6.6.1 has a recipient do.
fn date_value(headers : @mttp_core.Headers, response_time_ms : Int64) -> Int64 {
  match headers.get("date") {
    Some(text) => http_date(text, response_time_ms).unwrap_or(response_time_ms)
    None => response_time_ms
  }
}

///|
/// The explicit freshness lifetime in seconds, by the first rule of section
/// 4.2.1 that applies: s-maxage (shared caches), max-age, then Expires minus
/// Date, which is below zero for an Expires before Date. An invalid Expires
/// is a time in the past (section 5.3), a lifetime of 0. None when there is
/// no explicit expiration time.
pub fn freshness_lifetime(
  headers : @mttp_core.Headers,
  shared~ : Bool,
  response_time_ms~ : Int64,
) -> Int64? {
  let cc = CacheControl::parse(headers.get_all("cache-control"))
  if shared && cc.s_maxage is Some(s) {
    return Some(s)
  }
  if cc.max_age is Some(s) {
    return Some(s)
  }
  // The first Expires counts, as section 4.2.1 allows.
  guard headers.get("expires") is Some(text) else { return None }
  match http_date(text, response_time_ms) {
    None => Some(0L)
    Some(expires) => {
      let lifetime = floor_seconds(
        sub_ms(expires, date_value(headers, response_time_ms)),
      )
      Some(lifetime)
    }
  }
}

///|
/// The Age field's value: the first member of a list, ignored (0) when it
/// is not delta-seconds, as section 5.1 says.
fn age_value(headers : @mttp_core.Headers) -> Int64 {
  guard headers.get("age") is Some(text) else { return 0L }
  let first = match text.find(",") {
    Some(i) => text[:i]
    None => text[:]
  }
  delta_seconds(first.trim(chars=" \t")).unwrap_or(0L)
}

///|
/// The current age in whole seconds, as section 4.2.3 computes it, with the
/// conservative corrected_initial_age (the larger of the apparent age and
/// the corrected Age value). The arithmetic is in milliseconds, rounded
/// down once at the end, and saturates instead of wrapping; a clock read
/// earlier than a later one counts as no time passed.
pub fn current_age(
  headers : @mttp_core.Headers,
  request_time_ms~ : Int64,
  response_time_ms~ : Int64,
  now_ms~ : Int64,
) -> Int64 {
  let apparent_age = sub_ms(
    response_time_ms,
    date_value(headers, response_time_ms),
  ).max(0L)
  let response_delay = sub_ms(response_time_ms, request_time_ms).max(0L)
  let corrected_age_value = add_ms(age_value(headers) * 1000L, response_delay)
  let corrected_initial_age = apparent_age.max(corrected_age_value)
  let resident_time = sub_ms(now_ms, response_time_ms).max(0L)
  floor_seconds(add_ms(corrected_initial_age, resident_time))
}

///|
/// A stored response's freshness at `now_ms`, as a cache that sent the
/// request at `request_time_ms` and received the response at
/// `response_time_ms` sees it.
pub fn Freshness::of(
  headers : @mttp_core.Headers,
  shared~ : Bool,
  request_time_ms~ : Int64,
  response_time_ms~ : Int64,
  now_ms~ : Int64,
) -> Freshness {
  {
    cache_control: CacheControl::parse(headers.get_all("cache-control")),
    lifetime: freshness_lifetime(headers, shared~, response_time_ms~),
    age: current_age(headers, request_time_ms~, response_time_ms~, now_ms~),
    shared,
  }
}

///|
/// Whether the response is fresh: its lifetime exceeds its age. A fresh
/// response with `no-cache` still has to be validated before it is reused;
/// `reusable` says whether it may be.
pub fn Freshness::is_fresh(self : Freshness) -> Bool {
  self.lifetime is Some(l) && l > self.age
}

///|
/// Whether the response may be reused without validating it: fresh, and
/// without `no-cache` (section 5.2.2.4).
pub fn Freshness::reusable(self : Freshness) -> Bool {
  self.is_fresh() && !self.cache_control.no_cache
}

///|
/// How many seconds past its lifetime the response is; 0 while fresh, and
/// its whole age when it has no explicit lifetime.
pub fn Freshness::staleness(self : Freshness) -> Int64 {
  (self.age - self.lifetime.unwrap_or(0L)).max(0L)
}

///|
/// Whether a directive forbids serving the response stale (section
/// 4.2.4): no-cache, must-revalidate, and for a shared cache
/// proxy-revalidate or s-maxage.
pub fn Freshness::stale_forbidden(self : Freshness) -> Bool {
  let cc = self.cache_control
  cc.no_cache ||
  cc.must_revalidate ||
  (self.shared && (cc.proxy_revalidate || cc.s_maxage is Some(_)))
}

///|
/// Whether the stale response may be served while it is revalidated in the
/// background: within its `stale-while-revalidate` window (RFC 5861
/// section 3) and not forbidden. False while fresh.
pub fn Freshness::may_serve_while_revalidating(self : Freshness) -> Bool {
  !self.is_fresh() &&
  !self.stale_forbidden() &&
  self.lifetime is Some(_) &&
  self.cache_control.stale_while_revalidate is Some(window) &&
  self.staleness() <= window
}

///|
/// Whether the stale response may answer a request whose validation met an
/// error (a 500, 502, 503 or 504, or no response): within the
/// `stale-if-error` window of the response or of `request`, the request's
/// Cache-Control (RFC 5861 section 4), and not forbidden. False while
/// fresh.
pub fn Freshness::may_serve_on_error(
  self : Freshness,
  request? : CacheControl,
) -> Bool {
  guard !self.is_fresh() && !self.stale_forbidden() && self.lifetime is Some(_) else {
    return false
  }
  let window = match request.bind(r => r.stale_if_error) {
    Some(w) => Some(w)
    None => self.cache_control.stale_if_error
  }
  window is Some(w) && self.staleness() <= w
}

///|
/// Whether the response may be stored at all: not `no-store`, and for a
/// shared cache not `private` (section 3).
pub fn Freshness::storable(self : Freshness) -> Bool {
  !self.cache_control.no_store &&
  !(self.shared && self.cache_control.is_private)
}

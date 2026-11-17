///|
/// Range selection result; Partial carries inclusive byte offsets.
#non_exhaustive
#derive(Eq, Debug)
pub(all) enum RangeChoice {
  Full
  Partial(start~ : Int64, end~ : Int64)
  Unsatisfiable
}

///|
/// Compares range selection results.
pub extend RangeChoice with Eq::{equal, not_equal}

///|
/// Formats a range selection result for debugging.
pub extend RangeChoice with @debug.Debug::{to_repr}

///|
fn decimal(value : StringView) -> Int64? {
  if value.is_empty() {
    return None
  }
  for c in value; n = 0L {
    if c < '0' || c > '9' {
      return None
    }
    let d = (c.to_int() - 48).to_int64()
    if n > (9223372036854775807L - d) / 10L {
      return None
    }
    continue n * 10L + d
  } nobreak {
    Some(n)
  }
}

///|
/// Chooses one bytes range for GET. Invalid, oversized, multiple and unknown
/// ranges are ignored. If-Range requires a strong tag or exact date match.
pub fn choose_range(
  head : @mttp_core.RequestHead,
  length : Int64,
  validators : Validators,
) -> RangeChoice {
  if !(head.meth is Get) {
    return Full
  }
  let fields = head.headers.get_all("range")
  let mut bytes = 0
  let mut count = 0
  for field in fields {
    if field.length() > 1024 - bytes {
      return Full
    }
    bytes += @mttp_core.encode_utf8(field).length()
    if bytes > 1024 {
      return Full
    }
    for c in field {
      if c == ',' {
        count += 1
        if count >= 100 {
          return Full
        }
      }
    }
  }
  guard fields is [field] && count == 0 else { return Full }
  if head.headers.get("if-range") is Some(value) {
    let value = value.trim(chars=" \t").to_owned()
    let matches = if value.has_prefix("\"") || value.has_prefix("W/") {
      !value.has_prefix("W/") && validators.etag == Some(value)
    } else {
      date(value, validators) is Some(ms) &&
      validators.last_modified_ms is Some(modified) &&
      seconds(ms) == seconds(modified)
    }
    if !matches {
      return Full
    }
  }
  guard field.length() >= 6 && field[:6].to_owned().to_lower() == "bytes=" else {
    return Full
  }
  let spec = field[6:].trim(chars=" \t")
  guard spec.find("-") is Some(dash) else { return Full }
  let left = spec[:dash]
  let right = spec[dash + 1:]
  if left.is_empty() {
    guard decimal(right) is Some(suffix) else { return Full }
    if suffix == 0L || length <= 0L {
      return Unsatisfiable
    }
    return Partial(start=(length - suffix).max(0L), end=length - 1L)
  }
  guard decimal(left) is Some(start) else { return Full }
  let end = if right.is_empty() {
    length - 1L
  } else {
    guard decimal(right) is Some(end) else { return Full }
    if end < start {
      return Full
    }
    end.min(length - 1L)
  }
  if length <= 0L || start >= length {
    return Unsatisfiable
  }
  Partial(start~, end~)
}

///|
/// Formats an inclusive byte interval.
pub fn content_range(start : Int64, end : Int64, length : Int64) -> String {
  "bytes \{start}-\{end}/\{length}"
}

///|
/// Builds a bodyless 416 with the complete representation length.
pub fn range_not_satisfiable(length : Int64) -> @mttp_core.Response {
  @mttp_core.Response::new(
    416,
    headers=@mttp_core.Headers::of([("content-range", "bytes */\{length}")]),
  )
}

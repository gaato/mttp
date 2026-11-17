///|
/// Validators for an existing selected representation.
pub struct Validators {
  etag : String?
  last_modified_ms : Int64?
}

///|
/// Creates validators; omitted fields are unavailable.
pub fn Validators::new(etag? : String, last_modified_ms? : Int64) -> Validators {
  { etag, last_modified_ms, }
}

///|
#non_exhaustive
#derive(Eq, Debug)
pub(all) enum Precondition {
  Proceed
  NotModified
  Failed
}

///|
pub extend Precondition with Eq::{equal, not_equal}

///|
pub extend Precondition with @debug.Debug::{to_repr}

///|
fn date(value : String, validators : Validators) -> Int64? {
  @mttp_core.parse_http_date(
    value,
    now_unix_ms=validators.last_modified_ms.unwrap_or(0L),
  )
}

///|
fn tag_value(tag : StringView) -> StringView {
  if tag.has_prefix("W/") {
    tag[2:]
  } else {
    tag
  }
}

///|
fn seconds(ms : Int64) -> Int64 {
  let whole = ms / 1000L
  if ms < 0L && ms % 1000L != 0L {
    whole - 1L
  } else {
    whole
  }
}

///|
fn tag_matches(field : String, validators : Validators, strong : Bool) -> Bool {
  if field.trim(chars=" \t") == "*" {
    return true
  }
  guard validators.etag is Some(tag) else { return false }
  // Quoted opaque tags may contain commas, so do not split a tag list on commas.
  let mut i = 0
  while i < field.length() {
    while i < field.length() &&
          (field[i] == ' ' || field[i] == '\t' || field[i] == ',') {
      i += 1
    }
    let start = i
    if field[i:].has_prefix("W/") {
      i += 2
    }
    guard i < field.length() && field[i] == '"' else { return false }
    i += 1
    while i < field.length() && field[i] != '"' {
      i += 1
    }
    guard i < field.length() else { return false }
    i += 1
    let candidate = field[start:i]
    if (!strong || (!candidate.has_prefix("W/") && !tag.has_prefix("W/"))) &&
      tag_value(candidate) == tag_value(tag[:]) {
      return true
    }
    guard i == field.length() ||
      field[i] == ',' ||
      field[i] == ' ' ||
      field[i] == '\t' else {
      return false
    }
  }
  false
}

///|
/// Evaluates RFC 9110 section 13.2.2 for an existing representation.
/// Entity-tag fields suppress their corresponding date condition.
pub fn evaluate_preconditions(
  head : @mttp_core.RequestHead,
  validators : Validators,
) -> Precondition {
  let headers = head.headers
  if headers.contains("if-match") {
    if !headers
      .get_all("if-match")
      .iter()
      .any(v => tag_matches(v, validators, true)) {
      return Failed
    }
  } else if headers.get("if-unmodified-since") is Some(value) &&
    date(value, validators) is Some(limit) &&
    validators.last_modified_ms is Some(modified) &&
    seconds(modified) > seconds(limit) {
    return Failed
  }
  let safe = head.meth is Get || head.meth is Head
  if headers.contains("if-none-match") {
    if headers
      .get_all("if-none-match")
      .iter()
      .any(v => tag_matches(v, validators, false)) {
      return if safe { NotModified } else { Failed }
    }
  } else if safe &&
    headers.get("if-modified-since") is Some(value) &&
    date(value, validators) is Some(limit) &&
    validators.last_modified_ms is Some(modified) &&
    seconds(modified) <= seconds(limit) {
    return NotModified
  }
  Proceed
}

///|
/// Builds a bodyless 304 preserving cache metadata and setting available validators.
pub fn not_modified(
  validators : Validators,
  headers : @mttp_core.Headers,
) -> @mttp_core.Response {
  let mut headers = headers
    .remove("content-length")
    .remove("transfer-encoding")
    .remove("content-range")
  if validators.etag is Some(tag) {
    headers = headers.set("etag", tag)
  }
  if validators.last_modified_ms is Some(ms) {
    headers = headers.set("last-modified", @mttp_core.format_http_date(ms))
  }
  @mttp_core.Response::new(304, headers~)
}

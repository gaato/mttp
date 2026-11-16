// Cache-Control (RFC 9111 section 5.2) and delta-seconds (section 1.2.2).

///|
/// The largest delta-seconds kept: RFC 9111 section 1.2.2 has a cache
/// treat a larger value, or an overflow, as 2^31.
pub const MAX_DELTA_SECONDS : Int64 = 2147483648L

///|
/// `text` as delta-seconds (`1*DIGIT`), capped at `MAX_DELTA_SECONDS`;
/// None when it is not one.
pub fn delta_seconds(text : StringView) -> Int64? {
  guard text.length() > 0 else { return None }
  let mut value = 0L
  for c in text {
    guard c >= '0' && c <= '9' else { return None }
    value = value * 10L + (c.to_int() - '0'.to_int()).to_int64()
    if value > MAX_DELTA_SECONDS {
      value = MAX_DELTA_SECONDS
    }
  }
  Some(value)
}

///|
/// The directives of a Cache-Control field this package acts on. A
/// directive with seconds that are not delta-seconds counts as 0, which
/// makes the response stale, as section 4.2.1 encourages; when a
/// directive repeats, its first occurrence counts.
#derive(Eq, Debug)
pub(all) struct CacheControl {
  max_age : Int64?
  s_maxage : Int64?
  /// `no-cache`, with or without field names: the field-name form is
  /// treated as the unqualified one, the more restrictive reading section
  /// 5.2.2.4 allows.
  no_cache : Bool
  no_store : Bool
  /// `private`, with or without field names, likewise.
  is_private : Bool
  is_public : Bool
  must_revalidate : Bool
  proxy_revalidate : Bool
  immutable : Bool
  /// RFC 5861.
  stale_while_revalidate : Int64?
  /// RFC 5861.
  stale_if_error : Int64?
  /// Request directives (section 5.2.1).
  max_stale : Int64?
  /// `max-stale` without a value: any staleness is accepted.
  max_stale_any : Bool
  min_fresh : Int64?
  only_if_cached : Bool
}

///|
/// Compares directive sets.
pub extend CacheControl with Eq::{equal, not_equal}

///|
/// Debug representation of the directives.
pub extend CacheControl with @debug.Debug::{to_repr}

///|
/// Splits `line` at commas outside quoted strings.
fn split_list(line : String, out : Array[String]) -> Unit {
  let current = StringBuilder()
  let mut quoted = false
  let mut escaped = false
  for c in line {
    if quoted {
      current.write_char(c)
      if escaped {
        escaped = false
      } else if c == '\\' {
        escaped = true
      } else if c == '"' {
        quoted = false
      }
      continue
    }
    if c == '"' {
      quoted = true
      current.write_char(c)
    } else if c == ',' {
      out.push(current.to_string())
      current.reset()
    } else {
      current.write_char(c)
    }
  }
  out.push(current.to_string())
}

///|
/// A directive's argument: a token as it is, a quoted-string without its
/// quotes and escapes, or None for a quoted-string that does not close.
fn unquote(text : String) -> String? {
  guard text.has_prefix("\"") else { return Some(text) }
  let chars = text.to_array()
  let out = StringBuilder()
  let mut i = 1
  while i < chars.length() {
    let c = chars[i]
    if c == '\\' {
      guard i + 1 < chars.length() else { return None }
      out.write_char(chars[i + 1])
      i += 2
    } else if c == '"' {
      // The closing quote must end the argument.
      return if i == chars.length() - 1 { Some(out.to_string()) } else { None }
    } else {
      out.write_char(c)
      i += 1
    }
  }
  None
}

///|
/// Parses the lines of a Cache-Control field (request or response).
/// Directive names are compared case-insensitively; unknown directives are
/// ignored, as section 5.2.3 says.
pub fn CacheControl::parse(lines : ArrayView[String]) -> CacheControl {
  let directives = []
  // Field lines combine into one value, joined with commas (RFC 9110
  // section 5.2); a quoted-string may span them.
  split_list(lines.to_owned().join(", "), directives)
  let mut result : CacheControl = {
    max_age: None,
    s_maxage: None,
    no_cache: false,
    no_store: false,
    is_private: false,
    is_public: false,
    must_revalidate: false,
    proxy_revalidate: false,
    immutable: false,
    stale_while_revalidate: None,
    stale_if_error: None,
    max_stale: None,
    max_stale_any: false,
    min_fresh: None,
    only_if_cached: false,
  }
  for part in directives {
    let part = part.trim(chars=" \t").to_owned()
    guard part != "" else { continue }
    let (name, arg) = match part.find("=") {
      Some(i) =>
        (
          part[:i].trim(chars=" \t").to_lower(),
          // A quoted-string that does not close is malformed: no seconds.
          Some(unquote(part[i + 1:].trim(chars=" \t").to_owned()).unwrap_or("")),
        )
      None => (part.to_lower(), None)
    }
    // The first occurrence counts; malformed seconds count as 0.
    let seconds = (current : Int64?) => {
      match current {
        Some(_) => current
        None => Some(arg.bind(a => delta_seconds(a)).unwrap_or(0L))
      }
    }
    match name {
      "max-age" => result = { ..result, max_age: seconds(result.max_age), }
      "s-maxage" => result = { ..result, s_maxage: seconds(result.s_maxage), }
      "no-cache" => result = { ..result, no_cache: true, }
      "no-store" => result = { ..result, no_store: true, }
      "private" => result = { ..result, is_private: true, }
      "public" => result = { ..result, is_public: true, }
      "must-revalidate" => result = { ..result, must_revalidate: true, }
      "proxy-revalidate" => result = { ..result, proxy_revalidate: true, }
      "immutable" => result = { ..result, immutable: true, }
      "stale-while-revalidate" =>
        result = {
          ..result,
          stale_while_revalidate: seconds(result.stale_while_revalidate),
        }
      "stale-if-error" =>
        result = { ..result, stale_if_error: seconds(result.stale_if_error), }
      // Both forms of max-stale are one directive: the first counts.
      "max-stale" if result.max_stale is None && !result.max_stale_any =>
        if arg is None {
          result = { ..result, max_stale_any: true, }
        } else {
          result = { ..result, max_stale: seconds(result.max_stale), }
        }
      "min-fresh" =>
        result = { ..result, min_fresh: seconds(result.min_fresh), }
      "only-if-cached" => result = { ..result, only_if_cached: true, }
      _ => ()
    }
  }
  result
}

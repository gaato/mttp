///|
/// A pattern outside the supported ECMA subset, or beyond compilation limits.
pub(all) suberror UnsupportedPattern {
  UnsupportedPattern(String)
} derive(Debug)

///|
/// Formats a pattern-construction error.
pub extend UnsupportedPattern with @debug.Debug::{to_repr}

///|
fn pattern_source(ecma : String) -> String raise UnsupportedPattern {
  if ecma.length() > 1024 {
    raise UnsupportedPattern("pattern exceeds 1024 UTF-16 units")
  }
  let chars = ecma.to_array()
  let out = StringBuilder()
  let mut i = 0
  let mut in_class = false
  let mut class_first = 0
  let mut depth = 0
  let mut repeat_budget = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '\\' {
      i += 1
      guard chars.get(i) is Some(escaped) else {
        raise UnsupportedPattern("trailing escape")
      }
      let body = match escaped {
        'd' | 'D' => Some("0-9")
        'w' | 'W' => Some("A-Za-z0-9_")
        's' | 'S' =>
          Some(
            "\\t\\n\\r\\f\\v \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF",
          )
        _ => None
      }
      if body is Some(body) {
        let complement = escaped == 'D' || escaped == 'W' || escaped == 'S'
        if in_class {
          if complement ||
            (i >= 2 && chars[i - 2] == '-') ||
            chars.get(i + 1) == Some('-') {
            raise UnsupportedPattern(
              "class escape cannot be a range endpoint or complemented inside a class",
            )
          }
          out.write_string(body)
        } else {
          out.write_string(if complement { "[^" } else { "[" })
          out.write_string(body)
          out.write_char(']')
        }
      } else if "nrtfv\\.^$*+?{}[]()|-".contains_char(escaped) {
        out.write_char('\\')
        out.write_char(escaped)
      } else {
        raise UnsupportedPattern("unsupported escape")
      }
    } else if in_class {
      match c {
        '[' =>
          raise UnsupportedPattern(
            "nested/POSIX character classes are not ECMA syntax",
          )
        ']' => {
          if i == class_first {
            raise UnsupportedPattern("empty character classes are unsupported")
          }
          out.write_char(c)
          in_class = false
        }
        '-' if i == class_first || chars.get(i + 1) == Some(']') =>
          out.write_string("\\-")
        _ => out.write_char(c)
      }
    } else {
      match c {
        '[' => {
          in_class = true
          class_first = i + 1
          out.write_char(c)
          if chars.get(i + 1) == Some('^') {
            i += 1
            class_first = i + 1
            out.write_char('^')
          }
        }
        '.' => out.write_string("[^\\n\\r\\u2028\\u2029]")
        '(' => {
          depth += 1
          if depth > 32 {
            raise UnsupportedPattern("group nesting exceeds 32")
          }
          out.write_char(c)
          if chars.get(i + 1) == Some('?') {
            if chars.get(i + 2) != Some(':') {
              raise UnsupportedPattern(
                "only non-capturing group prefixes are supported",
              )
            }
            out.write_string("?:")
            i += 2
          }
        }
        ')' => {
          depth -= 1
          out.write_char(c)
        }
        '*' | '+' | '?' | '{' => {
          if i > 0 && chars[i - 1] == ')' {
            raise UnsupportedPattern(
              "group repetition is outside the bounded subset",
            )
          }
          if c == '{' {
            let start = i
            let mut count = 0
            let mut largest = 0
            i += 1
            while i < chars.length() && chars[i] != '}' {
              let n = chars[i]
              if n >= '0' && n <= '9' {
                count = count * 10 + n.to_int() - '0'.to_int()
                if count > 256 {
                  raise UnsupportedPattern("repeat count exceeds 256")
                }
                largest = largest.max(count)
              } else if n == ',' {
                count = 0
              } else {
                raise UnsupportedPattern("invalid repeat")
              }
              i += 1
            }
            if i == chars.length() {
              raise UnsupportedPattern("unterminated repeat")
            }
            repeat_budget += largest
            if repeat_budget > 4096 {
              raise UnsupportedPattern("repeat budget exceeds 4096")
            }
            for at in start..<=i {
              out.write_char(chars[at])
            }
          } else {
            out.write_char(c)
          }
        }
        _ => out.write_char(c)
      }
    }
    i += 1
  }
  if in_class || depth != 0 {
    raise UnsupportedPattern("unbalanced class or group")
  }
  out.to_string()
}

///|
/// An ECMA-style Unicode pattern with no flags. Supports literals, anchors,
/// dot, classes/ranges, d/w/s escapes and their complements, alternation,
/// groups and single-atom repetition. Group repetition, lookarounds,
/// backreferences, Unicode/hex escapes and flags are refused at construction.
/// Pattern length is capped at 1024 UTF-16 units, nesting at 32, repeat counts
/// at 256 and their sum at 4096. The original ECMA source is documented.
pub fn pattern(ecma : String) -> Validator[String] raise UnsupportedPattern {
  let source = pattern_source(ecma)
  let regex = @string.Regex(source) catch {
    error => raise UnsupportedPattern("invalid pattern: " + error.to_string())
  }
  custom(
    value => {
      if regex.execute(value) is Some(_) {
        None
      } else {
        Some("does not match pattern")
      }
    },
    keywords={ "pattern": Json(ecma) },
  )
}

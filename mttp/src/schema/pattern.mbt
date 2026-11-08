///|
/// A pattern outside the supported ECMA subset, or beyond compilation limits.
#derive(Debug)
pub(all) suberror UnsupportedPattern {
  UnsupportedPattern(String)
}

///|
/// Formats a pattern-construction error.
pub extend UnsupportedPattern with @debug.Debug::{to_repr}

///|
/// The longest pattern source, in UTF-16 units.
let max_pattern_units : Int32 = 1024

///|
/// The deepest group nesting.
let max_pattern_groups : Int32 = 32

///|
/// The largest count in one `{n}`, `{n,}` or `{n,m}`.
let max_repeat_count : Int32 = 256

///|
/// The most atoms the compiled pattern may hold once counted repetitions are
/// expanded: `a{3}` counts 3, `(?:ab){3}` counts 6. It bounds the automaton
/// `@string.Regex` builds, whose matching is linear in the input.
let max_pattern_atoms : Int32 = 4096

///|
/// One open group of the pattern being translated (the whole pattern is the
/// outermost): the atoms it holds so far, and the size of its last atom while
/// a quantifier may still apply to it.
priv struct Group {
  mut atoms : Int32
  mut last : Int32?
  mut lazy_allowed : Bool
}

///|
/// The `@string.Regex` class body of an ECMA class escape: `\d`, `\w`, `\s`
/// (their complements share the body). ECMA's `\s` is its WhiteSpace and
/// LineTerminator set, not POSIX `[[:space:]]`.
fn class_escape(c : Char) -> String? {
  match c {
    'd' | 'D' => Some("0-9")
    'w' | 'W' => Some("A-Za-z0-9_")
    's' | 'S' =>
      Some(
        "\\t\\n\\r\\f\\v \\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF",
      )
    _ => None
  }
}

///|
/// Writes a control escape (`\n \r \t \f \v`) or an escaped syntax
/// character in `@string.Regex` syntax; false for any other escape. `/`
/// needs no escape there.
fn write_escape(out : StringBuilder, escaped : Char) -> Bool {
  match escaped {
    '/' => out.write_char('/')
    'n' | 'r' | 't' | 'f' | 'v' => {
      out.write_char('\\')
      out.write_char(escaped)
    }
    _ if "^$\\.*+?()[]{}|-".contains_char(escaped) => {
      out.write_char('\\')
      out.write_char(escaped)
    }
    _ => return false
  }
  true
}

///|
/// Adds an atom of `size` to `group`, refusing growth past the budget.
fn add_atom(group : Group, size : Int32) -> Unit raise UnsupportedPattern {
  group.atoms += size
  group.last = Some(size)
  group.lazy_allowed = false
  if group.atoms > max_pattern_atoms {
    raise UnsupportedPattern(
      "pattern expands beyond \{max_pattern_atoms} atoms",
    )
  }
}

///|
/// Applies a quantifier that repeats the last atom up to `copies` times.
fn repeat_last(group : Group, copies : Int32) -> Unit raise UnsupportedPattern {
  guard group.last is Some(size) else {
    raise UnsupportedPattern("quantifier with nothing to repeat")
  }
  group.atoms += size * (copies - 1).max(0)
  group.last = None
  group.lazy_allowed = true
  if group.atoms > max_pattern_atoms {
    raise UnsupportedPattern(
      "pattern expands beyond \{max_pattern_atoms} atoms",
    )
  }
}

///|
/// Reads `{n}`, `{n,}` or `{n,m}` at `chars[start]`, returning the index
/// after it and how many copies of the atom it expands to.
fn counted_repeat(
  chars : Array[Char],
  start : Int32,
) -> (Int32, Int32) raise UnsupportedPattern {
  let numbers : Array[Int32?] = [None]
  let mut i = start + 1
  while i < chars.length() && chars[i] != '}' {
    match chars[i] {
      '0'..<='9' as digit => {
        let n = numbers[numbers.length() - 1].unwrap_or(0) * 10 +
          (digit.to_int() - '0'.to_int())
        if n > max_repeat_count {
          raise UnsupportedPattern("repeat count exceeds \{max_repeat_count}")
        }
        numbers[numbers.length() - 1] = Some(n)
      }
      ',' if numbers.length() == 1 => numbers.push(None)
      _ => raise UnsupportedPattern("invalid repeat")
    }
    i += 1
  }
  if i == chars.length() {
    raise UnsupportedPattern("unterminated repeat")
  }
  match numbers {
    [Some(n)] => (i + 1, n)
    [Some(n), None] => (i + 1, n + 1)
    [Some(n), Some(m)] if n <= m => (i + 1, m)
    [Some(_), Some(_)] => raise UnsupportedPattern("repeat range out of order")
    _ => raise UnsupportedPattern("invalid repeat")
  }
}

///|
/// Translates a character class starting after its `[` (and `^`) at
/// `chars[start]`, returning the index after its `]`. A class escape cannot
/// be complemented inside a class or be a range endpoint; a `-` is literal
/// only first or last.
fn translate_class(
  chars : Array[Char],
  start : Int32,
  out : StringBuilder,
) -> Int32 raise UnsupportedPattern {
  // Whether the previous item was one character, which may start a range,
  // and whether a range is waiting for its end.
  let mut can_start_range = false
  let mut in_range = false
  let mut i = start
  while i < chars.length() {
    let c = chars[i]
    match c {
      ']' => {
        if i == start {
          raise UnsupportedPattern("empty character classes are unsupported")
        }
        out.write_char(']')
        return i + 1
      }
      '[' =>
        raise UnsupportedPattern(
          "nested/POSIX character classes are not ECMA syntax",
        )
      '-' if i == start || chars.get(i + 1) == Some(']') => {
        out.write_string("\\-")
        can_start_range = false
      }
      '-' => {
        if !can_start_range {
          raise UnsupportedPattern(
            "a class range needs a character on each side",
          )
        }
        out.write_char('-')
        can_start_range = false
        in_range = true
        i += 1
        continue
      }
      '\\' => {
        guard chars.get(i + 1) is Some(escaped) else {
          raise UnsupportedPattern("trailing escape")
        }
        i += 1
        if class_escape(escaped) is Some(body) {
          if escaped is ('D' | 'W' | 'S') {
            raise UnsupportedPattern(
              "a complemented class escape inside a class is unsupported",
            )
          }
          if in_range ||
            (chars.get(i + 1) == Some('-') && chars.get(i + 2) != Some(']')) {
            raise UnsupportedPattern(
              "a class escape cannot be a range endpoint",
            )
          }
          out.write_string(body)
          can_start_range = false
        } else if write_escape(out, escaped) {
          can_start_range = !in_range
        } else {
          raise UnsupportedPattern("unsupported escape")
        }
      }
      _ => {
        out.write_char(c)
        can_start_range = !in_range
      }
    }
    in_range = false
    i += 1
  }
  raise UnsupportedPattern("unterminated character class")
}

///|
/// Translates ECMA source into `@string.Regex` syntax, refusing anything
/// outside the subset or past the limits above.
fn pattern_source(ecma : String) -> String raise UnsupportedPattern {
  if ecma.length() > max_pattern_units {
    raise UnsupportedPattern(
      "pattern exceeds \{max_pattern_units} UTF-16 units",
    )
  }
  let chars = ecma.to_array()
  let out = StringBuilder()
  let groups : Array[Group] = [{ atoms: 0, last: None, lazy_allowed: false, }]
  let mut i = 0
  while i < chars.length() {
    let group = groups[groups.length() - 1]
    let c = chars[i]
    match c {
      '\\' => {
        guard chars.get(i + 1) is Some(escaped) else {
          raise UnsupportedPattern("trailing escape")
        }
        if class_escape(escaped) is Some(body) {
          out.write_string(
            if escaped is ('D' | 'W' | 'S') {
              "[^"
            } else {
              "["
            },
          )
          out.write_string(body)
          out.write_char(']')
        } else if !write_escape(out, escaped) {
          raise UnsupportedPattern("unsupported escape")
        }
        add_atom(group, 1)
        i += 2
      }
      '[' => {
        out.write_char('[')
        let start = if chars.get(i + 1) == Some('^') {
          out.write_char('^')
          i + 2
        } else {
          i + 1
        }
        i = translate_class(chars, start, out)
        add_atom(group, 1)
      }
      '.' => {
        out.write_string("[^\\n\\r\\u2028\\u2029]")
        add_atom(group, 1)
        i += 1
      }
      '(' => {
        if groups.length() > max_pattern_groups {
          raise UnsupportedPattern(
            "group nesting exceeds \{max_pattern_groups}",
          )
        }
        out.write_char('(')
        i += 1
        if chars.get(i) == Some('?') {
          if chars.get(i + 1) != Some(':') {
            raise UnsupportedPattern(
              "only non-capturing group prefixes are supported",
            )
          }
          out.write_string("?:")
          i += 2
        }
        groups.push({ atoms: 0, last: None, lazy_allowed: false, })
      }
      ')' => {
        if groups.length() == 1 {
          raise UnsupportedPattern("unbalanced group")
        }
        ignore(groups.pop())
        out.write_char(')')
        add_atom(groups[groups.length() - 1], group.atoms)
        i += 1
      }
      '|' => {
        out.write_char('|')
        group.last = None
        group.lazy_allowed = false
        i += 1
      }
      '^' | '$' => {
        out.write_char(c)
        group.last = None
        group.lazy_allowed = false
        i += 1
      }
      '?' if group.lazy_allowed => {
        out.write_char('?')
        group.lazy_allowed = false
        i += 1
      }
      '*' | '+' | '?' => {
        repeat_last(group, if c == '+' { 2 } else { 1 })
        out.write_char(c)
        i += 1
      }
      '{' => {
        let (next, copies) = counted_repeat(chars, i)
        repeat_last(group, copies)
        for at in i..<next {
          out.write_char(chars[at])
        }
        i = next
      }
      ']' | '}' =>
        raise UnsupportedPattern("unescaped \{c} outside a class or repeat")
      _ => {
        out.write_char(c)
        add_atom(group, 1)
        i += 1
      }
    }
  }
  if groups.length() != 1 {
    raise UnsupportedPattern("unbalanced group")
  }
  out.to_string()
}

///|
/// An ECMA-262 pattern (Unicode mode, no flags) validating strings with
/// JSON Schema's search semantics: the value matches if the pattern matches
/// anywhere in it. Supported: literals, `^` and `$` (whole-input anchors),
/// `.` (any character but the four line terminators), classes and ranges,
/// the `\d \w \s` escapes and their complements outside classes, `\n \r \t
/// \f \v`, escaped syntax characters, alternation, `(...)` and `(?:...)`
/// groups, and greedy or lazy `* + ? {n} {n,} {n,m}` on any atom or group.
/// Lookarounds, backreferences, named groups, `\b`, Unicode and hex escapes,
/// and flags are refused when the validator is built.
///
/// Limits: 1024 UTF-16 units of source, 32 nested groups, counts up to 256,
/// and 4096 atoms once counted repetitions are expanded (`(?:ab){3}` is 6).
/// The schema states the original ECMA source.
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

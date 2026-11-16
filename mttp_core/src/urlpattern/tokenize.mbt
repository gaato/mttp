// The tokenizer of the URL Pattern Standard (section 2.1.2, "Tokenizing"),
// over code points.

///|
#derive(Eq)
priv enum TokenType {
  Open
  Close
  Regexp
  Name
  Char
  EscapedChar
  OtherModifier
  Asterisk
  End
  InvalidChar
}

///|
priv struct Token {
  kind : TokenType
  // The code point index where the token starts in the input.
  index : Int32
  value : String
}

///|
/// Whether `code` is in one of `ranges`, pairs of first and last.
fn in_ranges(ranges : FixedArray[Int32], code : Int32) -> Bool {
  let mut lo = 0
  let mut hi = ranges.length() / 2
  while lo < hi {
    let mid = (lo + hi) / 2
    if code < ranges[2 * mid] {
      hi = mid
    } else if code > ranges[2 * mid + 1] {
      lo = mid + 1
    } else {
      return true
    }
  }
  false
}

///|
/// Whether `c` may be in a group name: ECMAScript's IdentifierStart (ID_Start,
/// `$`, `_`) first, IdentifierPart (ID_Continue, `$`, ZWNJ, ZWJ) after.
fn is_name_char(c : Char, first : Bool) -> Bool {
  let code = c.to_int()
  if c == '$' || c == '_' {
    return true
  }
  if first {
    return in_ranges(id_start_ranges, code)
  }
  code == 0x200C || code == 0x200D || in_ranges(id_continue_ranges, code)
}

///|
/// The tokens of `input`; under the strict policy an error raises, under the
/// lenient one it becomes an InvalidChar token.
fn tokenize(
  input : Array[Char],
  lenient : Bool,
) -> Array[Token] raise PatternError {
  let tokens = []
  let n = input.length()
  let text = (start : Int32, end : Int32) => {
    String::from_array(input[start:end])
  }
  let mut index = 0
  fn error(next : Int32, value_pos : Int32) raise PatternError {
    guard lenient else { raise Invalid("tokenizing at \{value_pos}") }
    tokens.push({ kind: InvalidChar, index, value: text(value_pos, next), })
    index = next
  }
  fn add(kind : TokenType, next : Int32, value_pos : Int32, value_len : Int32) {
    tokens.push({ kind, index, value: text(value_pos, value_pos + value_len), })
    index = next
  }
  while index < n {
    let c = input[index]
    match c {
      '*' => add(Asterisk, index + 1, index, 1)
      '+' | '?' => add(OtherModifier, index + 1, index, 1)
      '\\' =>
        if index == n - 1 {
          error(index + 1, index)
        } else {
          add(EscapedChar, index + 2, index + 1, 1)
        }
      '{' => add(Open, index + 1, index, 1)
      '}' => add(Close, index + 1, index, 1)
      ':' => {
        let start = index + 1
        let mut pos = start
        while pos < n && is_name_char(input[pos], pos == start) {
          pos += 1
        }
        if pos <= start {
          error(start, index)
        } else {
          add(Name, pos, start, pos - start)
        }
      }
      '(' => {
        let mut depth = 1
        let start = index + 1
        let mut pos = start
        let mut failed = false
        while pos < n {
          let ch = input[pos]
          if ch.to_int() >= 0x80 || (pos == start && ch == '?') {
            failed = true
            break
          }
          if ch == '\\' {
            if pos == n - 1 || input[pos + 1].to_int() >= 0x80 {
              failed = true
              break
            }
            pos += 2
            continue
          }
          if ch == ')' {
            depth -= 1
            if depth == 0 {
              pos += 1
              break
            }
          } else if ch == '(' {
            depth += 1
            if pos == n - 1 || input[pos + 1] != '?' {
              failed = true
              break
            }
          }
          pos += 1
        }
        if failed {
          error(start, index)
          continue
        }
        let len = pos - start - 1
        if depth != 0 || len == 0 {
          error(start, index)
          continue
        }
        add(Regexp, pos, start, len)
      }
      _ => add(Char, index + 1, index, 1)
    }
  }
  tokens.push({ kind: End, index, value: "", })
  tokens
}

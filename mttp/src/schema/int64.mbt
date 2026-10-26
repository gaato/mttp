///|
// Converts a JSON decimal lexeme without rounding through Double. Only at
// most nineteen significant integer digits reach the final conversion, with checked
// parse_int64 providing the final signed range check.
fn exact_int64(text : String) -> Int64 raise DecodeFailure {
  let chars = text.to_array()
  let mut at = 0
  let negative = chars.get(0) == Some('-')
  if negative {
    at += 1
  }
  let digits = StringBuilder()
  let mut fraction = 0
  let mut integers = 0
  let mut dot = false
  while at < chars.length() && chars[at] != 'e' && chars[at] != 'E' {
    let c = chars[at]
    if c == '.' && !dot && integers > 0 {
      dot = true
    } else if c >= '0' && c <= '9' {
      digits.write_char(c)
      if dot {
        fraction += 1
      } else {
        integers += 1
      }
    } else {
      raise malformed("invalid integer number")
    }
    at += 1
  }
  if integers == 0 ||
    (dot && fraction == 0) ||
    (integers > 1 && chars[if negative { 1 } else { 0 }] == '0') {
    raise malformed("invalid decimal number")
  }
  let mut exponent = 0L
  if at < chars.length() {
    at += 1
    let minus = chars.get(at) == Some('-')
    if minus || chars.get(at) == Some('+') {
      at += 1
    }
    let start = at
    while at < chars.length() {
      let c = chars[at]
      if c < '0' || c > '9' {
        raise malformed("invalid integer exponent")
      }
      // Beyond this cap, no possible String length can cancel the exponent
      // into a nonzero int64; zero still accepts arbitrarily large exponents.
      exponent = (exponent * 10 + (c.to_int() - '0'.to_int()).to_int64()).min(
        4294967296L,
      )
      at += 1
    }
    if at == start {
      raise malformed("missing exponent")
    }
    if minus {
      exponent = -exponent
    }
  }
  let digits = digits.to_string().to_array()
  let mut first = 0
  while first < digits.length() && digits[first] == '0' {
    first += 1
  }
  if first == digits.length() {
    return 0
  }
  let shift = exponent - fraction.to_int64()
  let length = digits.length().to_int64() - first.to_int64() + shift
  if length < 1 || length > 19 {
    raise malformed("integer out of range or fractional")
  }
  let end = if shift < 0 {
    (digits.length().to_int64() + shift).to_int()
  } else {
    digits.length()
  }
  for i in end..<digits.length() {
    if digits[i] != '0' {
      raise malformed("fractional integer")
    }
  }
  let out = StringBuilder()
  if negative {
    out.write_char('-')
  }
  for i in first..<end {
    out.write_char(digits[i])
  }
  if shift > 0 {
    for _ in 0..<shift.to_int() {
      out.write_char('0')
    }
  }
  @string.parse_int64(out.to_string()) catch {
    _ => raise malformed("integer out of range")
  }
}

///|
/// Exact signed 64-bit JSON numbers. Parsed numbers must retain their lexeme
/// for values beyond Double's exact integer range; body() enables this. A
/// programmatically constructed number without a lexeme is accepted only in
/// the safe integer range. Encoding supplies the exact decimal lexeme.
pub let jint64 : JsonCodec[Int64] = {
  missing_: None,
  omit_: never_omit,
  from_: (j, path) => {
    try {
      match j {
        Number(_, repr=Some(text)) => exact_int64(text)
        Number(n, repr=None) if n == n.floor() &&
          n >= -9007199254740991.0 &&
          n <= 9007199254740991.0 => n.to_int64()
        _ => raise malformed("expected exact int64 number")
      }
    } catch {
      error =>
        raise invalid([{ path, code: "type", message: error.message(), }])
    }
  },
  to_: v => Json::number(v.to_double(), repr=v.to_string()),
  schema_: int64.schema(),
}

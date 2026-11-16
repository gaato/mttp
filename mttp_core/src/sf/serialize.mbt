// Serializing (RFC 9651 section 4.1): None where the RFC's algorithm fails,
// for a value the field syntax cannot carry. An empty List or Dictionary
// serializes to "", which section 4.1 says to send as no field at all.

///|
/// `list` as a field value, or None when a member cannot be written.
pub fn serialize_list(list : ArrayView[Member]) -> String? {
  let out = StringBuilder()
  for i, m in list {
    if i > 0 {
      out.write_string(", ")
    }
    guard write_member(out, m) else { return None }
  }
  Some(out.to_string())
}

///|
/// `dict` as a field value, or None when a key or member cannot be written.
pub fn serialize_dictionary(dict : ArrayView[(String, Member)]) -> String? {
  let out = StringBuilder()
  for i, pair in dict {
    let (name, m) = pair
    if i > 0 {
      out.write_string(", ")
    }
    guard write_key(out, name) else { return None }
    match m {
      Item({ value: Boolean(true), params, }) =>
        if !write_params(out, params) {
          return None
        }
      _ => {
        out.write_char('=')
        guard write_member(out, m) else { return None }
      }
    }
  }
  Some(out.to_string())
}

///|
/// `item` as a field value, or None when it cannot be written.
pub fn serialize_item(item : Item) -> String? {
  let out = StringBuilder()
  guard write_item(out, item) else { return None }
  Some(out.to_string())
}

///|
/// `value` alone, as it appears in a field, or None when it cannot be
/// written.
pub fn serialize_bare_item(value : BareItem) -> String? {
  let out = StringBuilder()
  guard write_bare(out, value) else { return None }
  Some(out.to_string())
}

///|
fn write_member(out : StringBuilder, m : Member) -> Bool {
  match m {
    Item(item) => write_item(out, item)
    InnerList(items, params) => {
      out.write_char('(')
      for i, item in items {
        if i > 0 {
          out.write_char(' ')
        }
        guard write_item(out, item) else { return false }
      }
      out.write_char(')')
      write_params(out, params)
    }
  }
}

///|
fn write_item(out : StringBuilder, item : Item) -> Bool {
  write_bare(out, item.value) && write_params(out, item.params)
}

///|
fn write_params(out : StringBuilder, params : Parameters) -> Bool {
  for pair in params {
    let (name, value) = pair
    out.write_char(';')
    guard write_key(out, name) else { return false }
    if value != Boolean(true) {
      out.write_char('=')
      guard write_bare(out, value) else { return false }
    }
  }
  true
}

///|
fn write_key(out : StringBuilder, name : String) -> Bool {
  guard name.length() > 0 else { return false }
  for i, c in name {
    let code = c.to_int()
    let ok = is_lcalpha(code) ||
      code == '*'.to_int() ||
      (
        i > 0 &&
        (
          is_digit(code) ||
          code == '_'.to_int() ||
          code == '-'.to_int() ||
          code == '.'.to_int()
        )
      )
    guard ok else { return false }
  }
  out.write_string(name)
  true
}

///|
fn write_bare(out : StringBuilder, value : BareItem) -> Bool {
  match value {
    Integer(n) => {
      guard n >= -MAX_DIGITS_VALUE && n <= MAX_DIGITS_VALUE else {
        return false
      }
      out.write_string(n.to_string())
    }
    Decimal(milli) => {
      guard milli >= -MAX_DIGITS_VALUE && milli <= MAX_DIGITS_VALUE else {
        return false
      }
      if milli < 0L {
        out.write_char('-')
      }
      let m = milli.abs()
      out.write_string((m / 1000L).to_string())
      out.write_char('.')
      let frac = (m % 1000L).to_int()
      // At least one fractional digit, and no trailing zeros after it.
      let digits = [frac / 100, frac / 10 % 10, frac % 10]
      let mut keep = 3
      while keep > 1 && digits[keep - 1] == 0 {
        keep -= 1
      }
      for d in digits[:keep] {
        out.write_char((d + 48).unsafe_to_char())
      }
    }
    String(s) => {
      out.write_char('"')
      for c in s {
        let code = c.to_int()
        guard code >= 0x20 && code <= 0x7E else { return false }
        if c == '"' || c == '\\' {
          out.write_char('\\')
        }
        out.write_char(c)
      }
      out.write_char('"')
    }
    Token(t) => {
      guard t.length() > 0 else { return false }
      for i, c in t {
        let code = c.to_int()
        let ok = if i == 0 {
          is_alpha(code) || c == '*'
        } else {
          code < 0x80 && (is_tchar(code) || c == ':' || c == '/')
        }
        guard ok else { return false }
      }
      out.write_string(t)
    }
    Bytes(b) => {
      out.write_char(':')
      out.write_string(@base64.encode(b))
      out.write_char(':')
    }
    Boolean(b) => out.write_string(if b { "?1" } else { "?0" })
    Date(seconds) => {
      guard seconds >= -MAX_DIGITS_VALUE && seconds <= MAX_DIGITS_VALUE else {
        return false
      }
      out.write_char('@')
      out.write_string(seconds.to_string())
    }
    DisplayString(s) => {
      out.write_string("%\"")
      for c in s {
        let code = c.to_int()
        // A lone surrogate is not Unicode text (section 4.1.11).
        guard code < 0xD800 || code > 0xDFFF else { return false }
        if code >= 0x20 && code <= 0x7E && c != '%' && c != '"' {
          out.write_char(c)
        } else {
          for b in utf8_bytes(code) {
            out.write_char('%')
            out.write_char("0123456789abcdef"[b >> 4].unsafe_to_char())
            out.write_char("0123456789abcdef"[b & 15].unsafe_to_char())
          }
        }
      }
      out.write_char('"')
    }
  }
  true
}

///|
/// The UTF-8 bytes of the scalar value `code`.
fn utf8_bytes(code : Int32) -> Array[Int32] {
  if code < 0x80 {
    [code]
  } else if code < 0x800 {
    [0xC0 | (code >> 6), 0x80 | (code & 0x3F)]
  } else if code < 0x10000 {
    [0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F)]
  } else {
    [
      0xF0 | (code >> 18),
      0x80 | ((code >> 12) & 0x3F),
      0x80 | ((code >> 6) & 0x3F),
      0x80 | (code & 0x3F),
    ]
  }
}

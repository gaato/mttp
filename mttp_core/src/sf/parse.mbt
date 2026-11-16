// Parsing (RFC 9651 section 4.2): each algorithm as the RFC states it, over
// the field's characters, failing (None) where it fails.

///|
priv suberror Fail

///|
/// The input: ASCII characters, and the next one to take.
priv struct Input {
  chars : Array[Int32]
  mut pos : Int32
}

///|
/// The field lines as one input, joined with ", " as section 4.2 combines
/// them; None for a character that is not ASCII.
fn Input::of(fields : Array[String]) -> Input? {
  let chars = []
  for i, field in fields {
    if i > 0 {
      chars.push(','.to_int())
      chars.push(' '.to_int())
    }
    for c in field {
      let code = c.to_int()
      guard code < 0x80 else { return None }
      chars.push(code)
    }
  }
  Some({ chars, pos: 0, })
}

///|
fn Input::empty(self : Input) -> Bool {
  self.pos >= self.chars.length()
}

///|
/// The next character, or -1 at the end.
fn Input::peek(self : Input) -> Int32 {
  if self.pos < self.chars.length() {
    self.chars[self.pos]
  } else {
    -1
  }
}

///|
fn Input::take(self : Input) -> Int32 {
  let c = self.peek()
  self.pos += 1
  c
}

///|
fn Input::skip_sp(self : Input) -> Unit {
  while self.peek() == ' '.to_int() {
    self.pos += 1
  }
}

///|
/// Optional whitespace: SP and HTAB.
fn Input::skip_ows(self : Input) -> Unit {
  while self.peek() == ' '.to_int() || self.peek() == '\t'.to_int() {
    self.pos += 1
  }
}

///|
fn is_digit(c : Int32) -> Bool {
  c >= '0'.to_int() && c <= '9'.to_int()
}

///|
fn is_lcalpha(c : Int32) -> Bool {
  c >= 'a'.to_int() && c <= 'z'.to_int()
}

///|
fn is_alpha(c : Int32) -> Bool {
  is_lcalpha(c) || (c >= 'A'.to_int() && c <= 'Z'.to_int())
}

///|
/// RFC 9110's tchar.
fn is_tchar(c : Int32) -> Bool {
  is_alpha(c) ||
  is_digit(c) ||
  "!#$%&'*+-.^_`|~".contains_char(c.unsafe_to_char())
}

///|
/// Runs `parse` over the whole field: leading SP is discarded, and anything
/// but trailing SP after the value fails (section 4.2, steps 2 to 6).
fn[T] top(fields : Array[String], parse : (Input) -> T raise Fail) -> T? {
  guard Input::of(fields) is Some(input) else { return None }
  input.skip_sp()
  let value = parse(input) catch { Fail => return None }
  input.skip_sp()
  guard input.empty() else { return None }
  Some(value)
}

///|
/// Parses the field lines `fields` as a List (RFC 9651 section 4.2.1), or
/// None if they are not one. A field with no lines, or only spaces, is an
/// empty List.
pub fn parse_list(fields : Array[String]) -> Array[Member]? {
  top(fields, list)
}

///|
/// Parses the field lines `fields` as a Dictionary (section 4.2.2), or None.
pub fn parse_dictionary(fields : Array[String]) -> Dictionary? {
  top(fields, dictionary)
}

///|
/// Parses the field lines `fields` as an Item (section 4.2.3), or None.
pub fn parse_item(fields : Array[String]) -> Item? {
  top(fields, item)
}

///|
fn list(input : Input) -> Array[Member] raise Fail {
  let members = []
  while !input.empty() {
    members.push(item_or_inner_list(input))
    input.skip_ows()
    if input.empty() {
      return members
    }
    guard input.take() == ','.to_int() else { raise Fail }
    input.skip_ows()
    if input.empty() {
      raise Fail
    }
  }
  members
}

///|
fn dictionary(input : Input) -> Dictionary raise Fail {
  let members = []
  let places = Map([])
  while !input.empty() {
    let name = key(input)
    let entry = if input.peek() == '='.to_int() {
      input.pos += 1
      item_or_inner_list(input)
    } else {
      Item({ value: Boolean(true), params: parameters(input), })
    }
    set_pair(members, places, name, entry)
    input.skip_ows()
    if input.empty() {
      return members
    }
    guard input.take() == ','.to_int() else { raise Fail }
    input.skip_ows()
    if input.empty() {
      raise Fail
    }
  }
  members
}

///|
fn item_or_inner_list(input : Input) -> Member raise Fail {
  if input.peek() == '('.to_int() {
    inner_list(input)
  } else {
    Item(item(input))
  }
}

///|
fn inner_list(input : Input) -> Member raise Fail {
  input.pos += 1
  let items = []
  while !input.empty() {
    input.skip_sp()
    if input.peek() == ')'.to_int() {
      input.pos += 1
      return InnerList(items, parameters(input))
    }
    items.push(item(input))
    let c = input.peek()
    guard c == ' '.to_int() || c == ')'.to_int() else { raise Fail }
  }
  raise Fail
}

///|
fn item(input : Input) -> Item raise Fail {
  let value = bare_item(input)
  { value, params: parameters(input), }
}

///|
fn bare_item(input : Input) -> BareItem raise Fail {
  let c = input.peek()
  if c == '-'.to_int() || is_digit(c) {
    number(input)
  } else if c == '"'.to_int() {
    String(string(input))
  } else if c == '*'.to_int() || is_alpha(c) {
    Token(token(input))
  } else if c == ':'.to_int() {
    Bytes(byte_sequence(input))
  } else if c == '?'.to_int() {
    Boolean(boolean(input))
  } else if c == '@'.to_int() {
    input.pos += 1
    match number(input) {
      Integer(seconds) => Date(seconds)
      _ => raise Fail
    }
  } else if c == '%'.to_int() {
    DisplayString(display_string(input))
  } else {
    raise Fail
  }
}

///|
fn parameters(input : Input) -> Parameters raise Fail {
  let params = []
  let places = Map([])
  while input.peek() == ';'.to_int() {
    input.pos += 1
    input.skip_sp()
    let name = key(input)
    let value = if input.peek() == '='.to_int() {
      input.pos += 1
      bare_item(input)
    } else {
      Boolean(true)
    }
    set_pair(params, places, name, value)
  }
  params
}

///|
fn key(input : Input) -> String raise Fail {
  let c = input.peek()
  guard is_lcalpha(c) || c == '*'.to_int() else { raise Fail }
  let out = StringBuilder()
  while !input.empty() {
    let c = input.peek()
    guard is_lcalpha(c) ||
      is_digit(c) ||
      c == '_'.to_int() ||
      c == '-'.to_int() ||
      c == '.'.to_int() ||
      c == '*'.to_int() else {
      break
    }
    out.write_char(c.unsafe_to_char())
    input.pos += 1
  }
  out.to_string()
}

///|
/// An Integer or a Decimal (section 4.2.4).
fn number(input : Input) -> BareItem raise Fail {
  let mut sign = 1L
  if input.peek() == '-'.to_int() {
    input.pos += 1
    sign = -1L
  }
  guard is_digit(input.peek()) else { raise Fail }
  let mut decimal = false
  let mut whole = 0L
  let mut frac = 0L
  let mut whole_len = 0
  let mut frac_len = 0
  while !input.empty() {
    let c = input.peek()
    if is_digit(c) {
      if decimal {
        frac = frac * 10L + (c - 48).to_int64()
        frac_len += 1
      } else {
        whole = whole * 10L + (c - 48).to_int64()
        whole_len += 1
      }
      input.pos += 1
    } else if !decimal && c == '.'.to_int() {
      guard whole_len <= 12 else { raise Fail }
      decimal = true
      input.pos += 1
    } else {
      break
    }
    // The RFC's limits on input_number's length: 15 characters for an
    // Integer, 16 with the point for a Decimal.
    if !decimal && whole_len > 15 {
      raise Fail
    }
    if decimal && whole_len + 1 + frac_len > 16 {
      raise Fail
    }
  }
  if !decimal {
    return Integer(sign * whole)
  }
  guard frac_len > 0 && frac_len <= 3 else { raise Fail }
  for _ in frac_len..<3 {
    frac = frac * 10L
  }
  Decimal(sign * (whole * 1000L + frac))
}

///|
/// A String (section 4.2.5).
fn string(input : Input) -> String raise Fail {
  input.pos += 1
  let out = StringBuilder()
  for ;; {
    guard !input.empty() else { raise Fail }
    let c = input.take()
    if c == '\\'.to_int() {
      guard !input.empty() else { raise Fail }
      let next = input.take()
      guard next == '"'.to_int() || next == '\\'.to_int() else { raise Fail }
      out.write_char(next.unsafe_to_char())
    } else if c == '"'.to_int() {
      return out.to_string()
    } else if c < 0x20 || c > 0x7E {
      raise Fail
    } else {
      out.write_char(c.unsafe_to_char())
    }
  }
}

///|
/// A Token (section 4.2.6).
fn token(input : Input) -> String {
  let out = StringBuilder()
  out.write_char(input.take().unsafe_to_char())
  while !input.empty() {
    let c = input.peek()
    guard is_tchar(c) || c == ':'.to_int() || c == '/'.to_int() else { break }
    out.write_char(c.unsafe_to_char())
    input.pos += 1
  }
  out.to_string()
}

///|
/// A Byte Sequence (section 4.2.7): base64 between colons, its padding and
/// its pad bits not checked, as the RFC recommends.
fn byte_sequence(input : Input) -> Bytes raise Fail {
  input.pos += 1
  let start = input.pos
  while !input.empty() && input.peek() != ':'.to_int() {
    let c = input.peek()
    guard is_alpha(c) ||
      is_digit(c) ||
      c == '+'.to_int() ||
      c == '/'.to_int() ||
      c == '='.to_int() else {
      raise Fail
    }
    input.pos += 1
  }
  guard !input.empty() else { raise Fail }
  let text = input.chars[start:input.pos]
  input.pos += 1
  decode_base64(text)
}

///|
/// base64 without its padding required: whole groups of four, then two or
/// three characters, optionally padded with `=`; `=` anywhere else fails.
fn decode_base64(text : ArrayView[Int32]) -> Bytes raise Fail {
  let mut n = text.length()
  while n > 0 && text[n - 1] == '='.to_int() {
    n -= 1
  }
  // Padding, when there is any, fills the last group of four.
  guard text.length() - n <= 2 && (text.length() == n || text.length() % 4 == 0) else {
    raise Fail
  }
  guard n % 4 != 1 else { raise Fail }
  let out = Buffer()
  let mut acc = 0
  let mut bits = 0
  for i in 0..<n {
    let c = text[i]
    let v = if c >= 'A'.to_int() && c <= 'Z'.to_int() {
      c - 'A'.to_int()
    } else if is_lcalpha(c) {
      c - 'a'.to_int() + 26
    } else if is_digit(c) {
      c - '0'.to_int() + 52
    } else if c == '+'.to_int() {
      62
    } else if c == '/'.to_int() {
      63
    } else {
      raise Fail
    }
    acc = (acc << 6) | v
    bits += 6
    if bits >= 8 {
      bits -= 8
      out.write_byte(((acc >> bits) & 0xFF).to_byte())
    }
  }
  out.to_bytes()
}

///|
/// A Boolean (section 4.2.8).
fn boolean(input : Input) -> Bool raise Fail {
  input.pos += 1
  match input.take() {
    0x31 => true
    0x30 => false
    _ => raise Fail
  }
}

///|
/// A Display String (section 4.2.10): `%"`, printable ASCII with `%` and
/// two lowercase hexadecimal digits for each byte of UTF-8 that is not, then
/// `"`; the bytes must be UTF-8.
fn display_string(input : Input) -> String raise Fail {
  input.pos += 1
  guard input.take() == '"'.to_int() else { raise Fail }
  let bytes = Buffer()
  for ;; {
    guard !input.empty() else { raise Fail }
    let c = input.take()
    guard c >= 0x20 && c <= 0x7E else { raise Fail }
    if c == '%'.to_int() {
      let hi = hex(input.take())
      let lo = hex(input.take())
      bytes.write_byte(((hi << 4) | lo).to_byte())
    } else if c == '"'.to_int() {
      return @utf8.decode(bytes.to_bytes()) catch { _ => raise Fail }
    } else {
      bytes.write_byte(c.to_byte())
    }
  }
}

///|
/// A lowercase hexadecimal digit's value.
fn hex(c : Int32) -> Int32 raise Fail {
  if is_digit(c) {
    c - '0'.to_int()
  } else if c >= 'a'.to_int() && c <= 'f'.to_int() {
    c - 'a'.to_int() + 10
  } else {
    raise Fail
  }
}

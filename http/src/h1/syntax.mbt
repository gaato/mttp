///|
fn malformed(detail : String) -> ParseError {
  ParseError(kind=Malformed, detail~)
}

///|
fn too_large(detail : String) -> ParseError {
  ParseError(kind=HeadTooLarge, detail~)
}

///|
/// A `tchar` of RFC 9110, section 5.6.2.
fn is_tchar(c : Char) -> Bool {
  match c {
    'a'..<='z' | 'A'..<='Z' | '0'..<='9' => true
    _ => "!#$%&'*+-.^_`|~".contains_char(c)
  }
}

///|
/// A nonempty `token`.
fn token(text : StringView) -> Bool {
  !text.is_empty() && text.iter().all(is_tchar)
}

///|
/// Whether `c` may appear in a field value, a reason phrase or a quoted
/// string: anything but controls other than HTAB, and DEL.
fn is_field_char(c : Char) -> Bool {
  !((c < ' ' && c != '\t') || c == '\u{7f}')
}

///|
/// Each octet as the code point of the same value (ISO-8859-1), so obs-text
/// survives unchanged and the writers can emit it back byte for byte.
fn latin1(bytes : BytesView) -> String {
  let out = StringBuilder()
  for byte in bytes {
    out.write_char(byte.to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
/// Strips HTTP optional whitespace (SP and HTAB) only, never Unicode
/// whitespace that obs-text may decode to.
fn ows(text : StringView) -> StringView {
  let mut start = 0
  let mut end = text.length()
  while start < end && (text[start] == ' ' || text[start] == '\t') {
    start += 1
  }
  while end > start && (text[end - 1] == ' ' || text[end - 1] == '\t') {
    end -= 1
  }
  text[start:end]
}

///|
/// Parses one field line of a head or trailer section. The name must be a
/// token directly followed by the colon, which refuses whitespace before the
/// colon and, because a folded continuation starts with SP or HTAB, obs-fold.
fn field(line : StringView) -> (String, String) raise ParseError {
  if line is [' ' | '\t', ..] {
    raise malformed("obsolete line folding")
  }
  guard line.find(":") is Some(colon) else {
    raise malformed("field line lacks colon")
  }
  let name = line[:colon]
  if !token(name) {
    raise malformed("invalid field name")
  }
  let value = line[colon + 1:]
  if !value.iter().all(is_field_char) {
    raise malformed("invalid field value")
  }
  (name.to_lower().to_owned(), ows(value).to_owned())
}

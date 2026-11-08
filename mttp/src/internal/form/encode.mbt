///|
/// Encodes ordered form pairs with the WHATWG form serializer.
pub fn encode(pairs : ArrayView[(String, String)]) -> String {
  let builder = StringBuilder()
  for i, pair in pairs {
    if i > 0 {
      builder.write_char('&')
    }
    let (name, value) = pair
    form_write(builder, name)
    builder.write_char('=')
    form_write(builder, value)
  }
  builder.to_string()
}

///|
/// Appends one name or value under the urlencoded serializer's rules.
fn form_write(builder : StringBuilder, text : String) -> Unit {
  for byte in @text.encode_utf8(text) {
    form_byte(builder, byte.to_int())
  }
}

///|
/// Appends one UTF-8 byte: kept, `+` for a space, or percent-encoded.
fn form_byte(builder : StringBuilder, byte : Int32) -> Unit {
  match byte {
    0x20 => builder.write_char('+')
    '0'..<='9' | 'A'..<='Z' | 'a'..<='z' | '*' | '-' | '.' | '_' =>
      builder.write_char(byte.unsafe_to_char())
    _ => {
      builder.write_char('%')
      builder.write_char(form_hex(byte >> 4))
      builder.write_char(form_hex(byte & 15))
    }
  }
}

///|
/// The uppercase hex digit for a nibble.
fn form_hex(nibble : Int32) -> Char {
  if nibble < 10 {
    ('0'.to_int() + nibble).unsafe_to_char()
  } else {
    ('A'.to_int() + nibble - 10).unsafe_to_char()
  }
}

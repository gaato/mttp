///|
let max_extension_header_bytes : Int32 = 16384

///|
let max_extensions : Int32 = 32

///|
let max_extension_params : Int32 = 32

///|
priv struct Scanner {
  chars : Array[Char]
  mut at : Int32
}

///|
fn Scanner::new(text : String) -> Scanner {
  { chars: text.to_array(), at: 0, }
}

///|
fn Scanner::skip_ows(self : Scanner) -> Unit {
  while self.chars.get(self.at) is Some(' ' | '\t') {
    self.at += 1
  }
}

///|
fn token_char(c : Char) -> Bool {
  c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9') ||
  "!#$%&'*+-.^_`|~".contains_char(c)
}

///|
fn Scanner::token(self : Scanner, what : String) -> String raise @ws.WsError {
  let start = self.at
  while self.chars.get(self.at) is Some(c) && token_char(c) {
    self.at += 1
  }
  if self.at == start {
    raise handshake(400, "expected \{what}")
  }
  String::from_array(self.chars[start:self.at])
}

///|
fn Scanner::quoted(self : Scanner) -> String raise @ws.WsError {
  self.at += 1
  let out = StringBuilder()
  while self.at < self.chars.length() {
    let c = self.chars[self.at]
    self.at += 1
    if c == '"' {
      return out.to_string()
    }
    if c == '\\' {
      guard self.chars.get(self.at) is Some(escaped) else {
        raise handshake(400, "unterminated quoted extension value")
      }
      if escaped == '\r' || escaped == '\n' || escaped.to_int() > 255 {
        raise handshake(400, "invalid quoted extension escape")
      }
      self.at += 1
      out.write_char(escaped)
    } else {
      let n = c.to_int()
      if c != '\t' && (n < 0x20 || n == 0x7f || n > 0xff) {
        raise handshake(400, "invalid quoted extension value")
      }
      out.write_char(c)
    }
  }
  raise handshake(400, "unterminated quoted extension value")
}

///|
fn Scanner::value(self : Scanner) -> String raise @ws.WsError {
  if self.chars.get(self.at) is Some('"') {
    self.quoted()
  } else {
    self.token("extension parameter value")
  }
}

///|
/// Parses a complete Sec-WebSocket-Extensions value. It admits at most 16 KiB,
/// 32 extension elements, and 32 parameters per element.
pub fn parse_extensions(value : String) -> Array[Extension] raise @ws.WsError {
  if value.length() > max_extension_header_bytes {
    raise handshake(400, "extension header exceeds 16384 bytes")
  }
  let scanner = Scanner::new(value)
  let extensions = []
  scanner.skip_ows()
  if scanner.at == scanner.chars.length() {
    raise handshake(400, "empty extension header")
  }
  for ;; {
    if extensions.length() >= max_extensions {
      raise handshake(400, "extension header exceeds 32 elements")
    }
    let name = scanner.token("extension name")
    let params = []
    scanner.skip_ows()
    while scanner.chars.get(scanner.at) is Some(';') {
      scanner.at += 1
      scanner.skip_ows()
      if params.length() >= max_extension_params {
        raise handshake(400, "extension exceeds 32 parameters")
      }
      let param_name = scanner.token("extension parameter name")
      scanner.skip_ows()
      let param_value = if scanner.chars.get(scanner.at) is Some('=') {
        scanner.at += 1
        scanner.skip_ows()
        Some(scanner.value())
      } else {
        None
      }
      params.push({ name: param_name, value: param_value, })
      scanner.skip_ows()
    }
    extensions.push({ name, params, })
    if scanner.at == scanner.chars.length() {
      break
    }
    if scanner.chars.get(scanner.at) != Some(',') {
      raise handshake(400, "expected comma between extensions")
    }
    scanner.at += 1
    scanner.skip_ows()
    if scanner.at == scanner.chars.length() {
      raise handshake(400, "trailing comma in extension header")
    }
  }
  extensions
}

///|
fn write_quoted(out : StringBuilder, value : String) -> Unit raise @ws.WsError {
  out.write_char('"')
  for c in value {
    let n = c.to_int()
    if c != '\t' && (n < 0x20 || n == 0x7f || n > 0xff) {
      raise handshake(400, "invalid extension parameter value")
    }
    if c == '"' || c == '\\' {
      out.write_char('\\')
    }
    out.write_char(c)
  }
  out.write_char('"')
}

///|
/// Prints parsed extension elements canonically and enforces the parser bounds.
pub fn print_extensions(
  extensions : ArrayView[Extension],
) -> String raise @ws.WsError {
  if extensions.is_empty() {
    raise handshake(400, "empty extension list")
  }
  if extensions.length() > max_extensions {
    raise handshake(400, "extension header exceeds 32 elements")
  }
  let out = StringBuilder()
  for i, extension in extensions {
    if extension.name.is_empty() || !extension.name.iter().all(token_char) {
      raise handshake(400, "invalid extension name")
    }
    if extension.params.length() > max_extension_params {
      raise handshake(400, "extension exceeds 32 parameters")
    }
    if i > 0 {
      out.write_string(", ")
    }
    out.write_string(extension.name)
    for param in extension.params {
      if param.name.is_empty() || !param.name.iter().all(token_char) {
        raise handshake(400, "invalid extension parameter name")
      }
      out.write_string("; ")
      out.write_string(param.name)
      if param.value is Some(value) {
        out.write_char('=')
        if !value.is_empty() && value.iter().all(token_char) {
          out.write_string(value)
        } else {
          write_quoted(out, value)
        }
      }
    }
    if out.to_string().length() > max_extension_header_bytes {
      raise handshake(400, "extension header exceeds 16384 bytes")
    }
  }
  out.to_string()
}

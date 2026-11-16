// The encoding callbacks of section 3.1, which canonicalize fixed text as
// the WHATWG URL parser would, written out for the states they run. The
// dummy URL they use is https://dummy.invalid/, a special URL.

///|
fn without_tab_or_newline(value : String) -> String {
  if value.iter().any(c => c is ('\t' | '\n' | '\r')) {
    String::from_iter(value.iter().filter(c => !(c is ('\t' | '\n' | '\r'))))
  } else {
    value
  }
}

///|
/// Which code points a percent-encode set encodes besides C0 controls and
/// everything past U+007E.
priv enum EncodeSet {
  C0
  Fragment
  Query
  SpecialQuery
  Path
  Userinfo
}

///|
fn in_set(c : Char, set : EncodeSet) -> Bool {
  let code = c.to_int()
  if code < 0x20 || code > 0x7E {
    return true
  }
  let fragment = c is (' ' | '"' | '<' | '>' | '`')
  let query = c is (' ' | '"' | '#' | '<' | '>')
  let path = query || c is ('?' | '^' | '`' | '{' | '}')
  match set {
    C0 => false
    Fragment => fragment
    Query => query
    SpecialQuery => query || c == '\''
    Path => path
    Userinfo =>
      path || c is ('/' | ':' | ';' | '=' | '@' | '[' | '\\' | ']' | '^' | '|')
  }
}

///|
let hex_digits : String = "0123456789ABCDEF"

///|
fn percent_encode(out : StringBuilder, c : Char, set : EncodeSet) -> Unit {
  guard in_set(c, set) else { return out.write_char(c) }
  for b in @utf8.encode(c.to_string()) {
    let v = b.to_int()
    out.write_char('%')
    out.write_char(hex_digits[v >> 4].unsafe_to_char())
    out.write_char(hex_digits[v & 15].unsafe_to_char())
  }
}

///|
fn encode_all(value : String, set : EncodeSet) -> String {
  let out = StringBuilder()
  for c in value {
    percent_encode(out, c, set)
  }
  out.to_string()
}

///|
fn canonicalize_protocol(value : String) -> String raise PatternError {
  guard value != "" else { return value }
  // The callback parses value + "://dummy.invalid/" without a URL given,
  // which first strips leading C0 controls and spaces.
  let chars = without_tab_or_newline(value).to_array()
  let mut start = 0
  while start < chars.length() && chars[start].to_int() <= 0x20 {
    start += 1
  }
  let chars = chars[start:].to_owned()
  guard chars.length() > 0 && chars[0].is_ascii_alphabetic() else {
    raise Invalid("protocol \{value}")
  }
  // The scheme state ends at the first `:`; what follows it is the rest of
  // a URL the parser reads, as "data:foo://dummy.invalid/" is.
  let mut end = 0
  while end < chars.length() && chars[end] != ':' {
    end += 1
  }
  let scheme = chars[:end].to_owned()
  // The callback parses value + "://dummy.invalid/" whole: for a special
  // scheme other than file, what follows the first `:` must be an
  // authority with a valid host and port, as "https:@a/" is and "https:#"
  // and "https:[bad" are not.
  if end < chars.length() {
    let lower = String::from_array(scheme).to_lower()
    let rest = String::from_array(chars[end + 1:]) + "://dummy.invalid/"
    if lower != "file" && special_schemes.contains(lower) {
      check_authority(rest, value, special=true, require_host=true)
    } else if lower == "file" {
      // file: may have an empty host; a host it has must parse.
      if rest.has_prefix("//") || rest.has_prefix("\\\\") {
        check_authority(rest, value, special=true, require_host=false)
      }
    } else if rest.has_prefix("//") {
      check_authority(rest, value, special=false, require_host=false)
    }
  }
  let chars = scheme
  for c in chars {
    guard c.is_ascii_alphabetic() ||
      c.is_ascii_digit() ||
      c is ('+' | '-' | '.') else {
      raise Invalid("protocol \{value}")
    }
  }
  String::from_array(chars).to_lower()
}

///|
/// Checks the authority that `rest`, the part of a special URL after its
/// scheme's `:`, starts with, as the URL parser reads it: slashes skipped,
/// credentials up to the last `@`, then a host that parses and a port of
/// at most 65535.
fn check_authority(
  rest : String,
  value : String,
  special~ : Bool,
  require_host~ : Bool,
) -> Unit raise PatternError {
  let r = rest.to_array()
  let mut i = 0
  while i < r.length() && (r[i] == '/' || (special && r[i] == '\\')) {
    i += 1
  }
  let mut end = i
  while end < r.length() &&
        !(r[end] is ('/' | '?' | '#') || (special && r[end] == '\\')) {
    end += 1
  }
  let mut start = i
  for j in i..<end {
    if r[j] == '@' {
      start = j + 1
    }
  }
  let hostport = String::from_array(r[start:end])
  let (host, port) = if hostport.has_prefix("[") {
    match hostport.find("]") {
      Some(k) => (hostport[:k + 1].to_owned(), hostport[k + 1:].to_owned())
      None => raise Invalid("protocol \{value}")
    }
  } else {
    match hostport.find(":") {
      Some(k) => (hostport[:k].to_owned(), hostport[k:].to_owned())
      None => (hostport, "")
    }
  }
  if host == "" {
    guard !require_host else { raise Invalid("protocol \{value}") }
  } else if special || host.has_prefix("[") {
    canonicalize_hostname(host) |> ignore
  } else {
    opaque_host(host) |> ignore
  }
  if port != "" {
    guard port.has_prefix(":") else { raise Invalid("protocol \{value}") }
    let digits = port[1:].to_owned()
    guard digits.iter().all(c => c.is_ascii_digit()) else {
      raise Invalid("protocol \{value}")
    }
    if digits != "" {
      let trimmed = digits.trim_start(chars="0").to_owned()
      guard trimmed.length() <= 5 &&
        (
          trimmed == "" ||
          (@string.parse_int(trimmed) catch { _ => 99999 }) <= 65535
        ) else {
        raise Invalid("protocol \{value}")
      }
    }
  }
}

///|
fn canonicalize_username(value : String) -> String {
  encode_all(value, Userinfo)
}

///|
fn canonicalize_password(value : String) -> String {
  encode_all(value, Userinfo)
}

///|
fn is_forbidden_host(c : Char) -> Bool {
  c
  is ('\u{0}'
  | '\t'
  | '\n'
  | '\r'
  | ' '
  | '#'
  | '/'
  | ':'
  | '<'
  | '>'
  | '?'
  | '@'
  | '['
  | '\\'
  | ']'
  | '^'
  | '|')
}

///|
fn is_forbidden_domain(c : Char) -> Bool {
  is_forbidden_host(c) || c.to_int() < 0x20 || c == '%' || c.to_int() == 0x7F
}

///|
fn hex_value(c : Char) -> Int32? {
  if c.is_ascii_digit() {
    Some(c.to_int() - '0'.to_int())
  } else if c >= 'a' && c <= 'f' {
    Some(c.to_int() - 'a'.to_int() + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(c.to_int() - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
/// Percent-decodes `value` to bytes, as the host parser does before the
/// domain is checked; None when the bytes are not UTF-8.
fn percent_decode(value : String) -> String? {
  guard value.contains_char('%') else { return Some(value) }
  let bytes = Buffer()
  let chars = value.to_array()
  let mut i = 0
  while i < chars.length() {
    let c = chars[i]
    if c == '%' &&
      i + 2 < chars.length() + 0 &&
      hex_value(chars[i + 1]) is Some(hi) &&
      hex_value(chars[i + 2]) is Some(lo) {
      bytes.write_byte((hi * 16 + lo).to_byte())
      i += 3
      continue
    }
    bytes.write_bytes(@utf8.encode(c.to_string()))
    i += 1
  }
  try @utf8.decode(bytes.to_bytes()) catch {
    _ => None
  } noraise {
    s => Some(s)
  }
}

///|
/// One IPv4 number as the IPv4 number parser reads it: decimal, `0x` hex or
/// leading-zero octal. None when it is not a number.
fn ipv4_number(part : String) -> Int64? {
  guard part != "" else { return None }
  let (digits, radix) = if part.has_prefix("0x") || part.has_prefix("0X") {
    (part[2:].to_owned(), 16)
  } else if part.length() > 1 && part.has_prefix("0") {
    (part[1:].to_owned(), 8)
  } else {
    (part, 10)
  }
  let mut value = 0L
  for c in digits {
    guard hex_value(c) is Some(d) && d < radix else { return None }
    value = value * radix.to_int64() + d.to_int64()
    if value > 0xFFFF_FFFFL * 256L {
      // Already too large for any position; keep it bounded.
      value = 0xFFFF_FFFFL * 256L
    }
  }
  Some(value)
}

///|
/// Whether the host parser reads `host` as an IPv4 address: its last label,
/// past one trailing empty label, is a number.
fn ends_in_number(host : String) -> Bool {
  let labels = host.split(".").map(l => l.to_owned()).collect()
  if labels.length() > 1 && labels[labels.length() - 1] == "" {
    labels.pop() |> ignore
  }
  let last = labels[labels.length() - 1]
  if last != "" && last.iter().all(c => c.is_ascii_digit()) {
    return true
  }
  ipv4_number(last) is Some(_) &&
  (last.has_prefix("0x") || last.has_prefix("0X"))
}

///|
fn ipv4_host(host : String) -> String raise PatternError {
  let labels = host.split(".").map(l => l.to_owned()).collect()
  if labels.length() > 1 && labels[labels.length() - 1] == "" {
    labels.pop() |> ignore
  }
  guard labels.length() <= 4 else { raise Invalid("IPv4 \{host}") }
  let numbers = []
  for label in labels {
    guard ipv4_number(label) is Some(n) else { raise Invalid("IPv4 \{host}") }
    numbers.push(n)
  }
  let last = numbers.length() - 1
  for i in 0..<last {
    guard numbers[i] <= 255L else { raise Invalid("IPv4 \{host}") }
  }
  let limit = 1L << (8 * (5 - numbers.length()))
  guard numbers[last] < limit else { raise Invalid("IPv4 \{host}") }
  let mut ipv4 = numbers[last]
  for i in 0..<last {
    ipv4 += numbers[i] << (8 * (3 - i))
  }
  let octets = [
    ipv4 >> 24,
    (ipv4 >> 16) & 255L,
    (ipv4 >> 8) & 255L,
    ipv4 & 255L,
  ]
  octets.map(o => o.to_string()).join(".")
}

///|
fn canonicalize_hostname(value : String) -> String raise PatternError {
  guard value != "" else { return value }
  let value = without_tab_or_newline(value)
  // The hostname state stops at these; with a state override the parse
  // ends there.
  let mut end = value.length()
  let mut brackets = false
  for i, c in value {
    if c == '[' {
      brackets = true
    } else if c == ']' {
      brackets = false
    }
    // With the hostname state override, a `:` outside brackets fails.
    guard c != ':' || brackets else {
      raise Invalid("a : in hostname \{value}")
    }
    if c is ('/' | '?' | '#' | '\\') {
      end = i
      break
    }
  }
  let host = value[:end].to_owned()
  guard host != "" else { raise Invalid("an empty hostname") }
  if host.has_prefix("[") {
    guard host.has_suffix("]") else { raise Invalid("IPv6 \{host}") }
    let url = @mttp_core.Url::parse("https://\{host}/") catch {
      _ => raise Invalid("IPv6 \{host}")
    }
    // An authority between "//" and "/" always gives Url a host.
    return "[\{url.host.unwrap_or("")}]"
  }
  guard percent_decode(host) is Some(domain) else {
    raise Invalid("hostname \{host}")
  }
  guard domain.iter().all(c => c.to_int() < 0x80) else {
    raise Unsupported("an internationalized hostname needs IDNA")
  }
  let domain = domain.to_lower()
  guard !domain.iter().any(is_forbidden_domain) else {
    raise Invalid("hostname \{host}")
  }
  if ends_in_number(domain) {
    ipv4_host(domain)
  } else {
    domain
  }
}

///|
/// A non-special URL's host as the opaque-host parser keeps it: neither
/// lowercased nor read as an IPv4 address, C0 controls percent-encoded.
fn opaque_host(value : String) -> String raise PatternError {
  guard !value.iter().any(c => is_forbidden_host(c) && c != '[' && c != ']') else {
    raise Invalid("opaque host \{value}")
  }
  encode_all(value, C0)
}

///|
fn canonicalize_ipv6_hostname(value : String) -> String raise PatternError {
  for c in value {
    guard c.is_ascii_hexdigit() || c is ('[' | ']' | ':') else {
      raise Invalid("IPv6 hostname \{value}")
    }
  }
  value.to_lower()
}

///|
fn default_port(scheme : String) -> String? {
  match scheme {
    "http" | "ws" => Some("80")
    "https" | "wss" => Some("443")
    "ftp" => Some("21")
    _ => None
  }
}

///|
fn canonicalize_port(
  value : String,
  protocol : String?,
) -> String raise PatternError {
  guard value != "" else { return value }
  let value = without_tab_or_newline(value)
  let digits = StringBuilder()
  for c in value {
    guard c.is_ascii_digit() else { break }
    digits.write_char(c)
  }
  let digits = digits.to_string()
  guard digits != "" else { raise Invalid("port \{value}") }
  let trimmed = match digits.iter().find_first(c => c != '0') {
    None => "0"
    Some(_) => {
      let mut i = 0
      while digits[i] == '0' {
        i += 1
      }
      digits[i:].to_owned()
    }
  }
  guard trimmed.length() <= 5 else { raise Invalid("port \{value}") }
  let mut number = 0
  for c in trimmed {
    number = number * 10 + (c.to_int() - '0'.to_int())
  }
  guard number <= 65535 else { raise Invalid("port \{value}") }
  if protocol.bind(default_port) == Some(trimmed) {
    ""
  } else {
    trimmed
  }
}

///|
fn is_single_dot(segment : String) -> Bool {
  segment == "." || segment.to_lower() == "%2e"
}

///|
fn is_double_dot(segment : String) -> Bool {
  segment.to_lower() is (".." | ".%2e" | "%2e." | "%2e%2e")
}

///|
/// The path state of the URL parser on a special URL, from an empty path:
/// `/` and `\` end segments, dot segments are resolved, the rest is
/// percent-encoded with the path set.
fn parse_special_path(value : String, file~ : Bool = false) -> Array[String] {
  let path = []
  let chars = value.to_array()
  // The path start state takes one leading slash.
  let mut i = if chars.length() > 0 && chars[0] is ('/' | '\\') { 1 } else { 0 }
  let buffer = StringBuilder()
  while i <= chars.length() {
    let at_end = i == chars.length()
    if at_end || chars[i] is ('/' | '\\') {
      let segment = buffer.to_string()
      buffer.reset()
      let slash = !at_end
      if is_double_dot(segment) {
        // A file: path keeps a drive letter at its root ("shorten").
        if !(file && path.length() == 1 && is_drive_letter(path[0], true)) {
          path.pop() |> ignore
        }
        if !slash {
          path.push("")
        }
      } else if is_single_dot(segment) {
        if !slash {
          path.push("")
        }
      } else if file && path.is_empty() && is_drive_letter(segment, false) {
        // A file: path's first segment C| is the drive C:.
        path.push(segment[:1].to_owned() + ":")
      } else {
        path.push(segment)
      }
    } else {
      percent_encode(buffer, chars[i], Path)
    }
    i += 1
  }
  path
}

///|
/// Whether `segment` is a Windows drive letter (`C:` or `C|`), or with
/// `normalized` only `C:`.
fn is_drive_letter(segment : String, normalized : Bool) -> Bool {
  let chars = segment.to_array()
  chars.length() == 2 &&
  chars[0].is_ascii_alphabetic() &&
  (chars[1] == ':' || (!normalized && chars[1] == '|'))
}

///|
/// A file: URL's path as the path state keeps it: dot segments resolved
/// without removing a drive letter, and `C|` read as `C:`.
fn canonicalize_file_path(value : String) -> String {
  let out = StringBuilder()
  for segment in parse_special_path(without_tab_or_newline(value), file=true) {
    out.write_char('/')
    out.write_string(segment)
  }
  out.to_string()
}

///|
fn canonicalize_pathname(value : String) -> String {
  guard value != "" else { return value }
  let leading_slash = value.has_prefix("/")
  let modified = if leading_slash { value } else { "/-" + value }
  let path = parse_special_path(without_tab_or_newline(modified))
  let out = StringBuilder()
  for segment in path {
    out.write_char('/')
    out.write_string(segment)
  }
  let result = out.to_string()
  if leading_slash {
    result
  } else {
    result[2:].to_owned()
  }
}

///|
fn canonicalize_opaque_pathname(value : String) -> String {
  guard value != "" else { return value }
  // The opaque path state ends at `?` and `#`, even with a state override.
  let chars = without_tab_or_newline(value).to_array()
  let mut end = 0
  while end < chars.length() && !(chars[end] is ('?' | '#')) {
    end += 1
  }
  let out = StringBuilder()
  for i in 0..<end {
    // A space just before `?` or `#` is encoded, so it is not lost when
    // the path is cut there.
    if chars[i] == ' ' && i + 1 < chars.length() && chars[i + 1] is ('?' | '#') {
      out.write_string("%20")
    } else {
      percent_encode(out, chars[i], C0)
    }
  }
  out.to_string()
}

///|
fn canonicalize_search(value : String) -> String {
  guard value != "" else { return value }
  encode_all(without_tab_or_newline(value), SpecialQuery)
}

///|
/// A query as the URL parser keeps it for a URL of `special` scheme or not.
fn canonical_query(value : String, special : Bool) -> String {
  encode_all(
    without_tab_or_newline(value),
    if special {
      SpecialQuery
    } else {
      Query
    },
  )
}

///|
fn canonicalize_hash(value : String) -> String {
  guard value != "" else { return value }
  encode_all(without_tab_or_newline(value), Fragment)
}

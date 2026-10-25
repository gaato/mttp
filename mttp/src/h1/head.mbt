///|
/// Finds the first complete CRLF-delimited head within max bytes, returning
/// its exclusive end. Rejects bare CR/LF. Use HeadDecoder for incremental
/// input so already-scanned prefixes are not repeatedly scanned.
pub fn scan_head(buf : BytesView, max~ : Int32) -> Int32? raise ParseError {
  if max < 0 {
    raise malformed("negative head limit")
  }
  let mut previous_cr = false
  let mut matched = 0
  for i, byte in buf {
    if i >= max {
      raise ParseError(kind=HeadTooLarge, detail="head exceeds limit")
    }
    if (previous_cr && byte != b'\n') || (byte == b'\n' && !previous_cr) {
      raise malformed("head requires CRLF")
    }
    previous_cr = byte == b'\r'
    matched = match (matched, byte) {
      (0 | 2, b'\r') => matched + 1
      (1 | 3, b'\n') => matched + 1
      _ => 0
    }
    if matched == 4 {
      return Some(i + 1)
    }
  }
  None
}

///|
/// Result of feeding a head accumulator. Bytes after consumed belong to the
/// body or a pipelined message and are never retained by the accumulator.
pub struct HeadResult {
  head : Bytes?
  consumed : Int32
}

///|
/// A bounded, linear-time head accumulator. After completion, later feeds
/// return the same head with zero consumed bytes. Errors are sticky.
pub struct HeadDecoder {
  priv max : Int32
  priv buffer : Buffer
  priv mut matched : Int32
  priv mut previous_cr : Bool
  priv mut complete : Bytes?
  priv mut failure : ParseError?
}

///|
/// Starts a head accumulator, defaulting to 16 KiB.
pub fn HeadDecoder::new(max~ : Int32 = 16384) -> HeadDecoder {
  {
    max,
    buffer: Buffer(),
    matched: 0,
    previous_cr: false,
    complete: None,
    failure: None,
  }
}

///|
/// Appends only the bytes needed to finish the head, up to the configured cap.
/// The synchronous catch records the exact error for subsequent feeds.
#warnings("-fragile_catch_all")
pub fn HeadDecoder::feed(
  self : HeadDecoder,
  bytes : BytesView,
) -> HeadResult raise ParseError {
  if self.failure is Some(error) {
    raise error
  }
  if self.complete is Some(head) {
    return { head: Some(head), consumed: 0, }
  }
  try {
    if self.max < 0 {
      raise malformed("negative head limit")
    }
    for i, byte in bytes {
      if self.buffer.length() >= self.max {
        raise ParseError(kind=HeadTooLarge, detail="head exceeds limit")
      }
      if (self.previous_cr && byte != b'\n') ||
        (byte == b'\n' && !self.previous_cr) {
        raise malformed("head requires CRLF")
      }
      self.previous_cr = byte == b'\r'
      self.buffer.write_byte(byte)
      self.matched = match (self.matched, byte) {
        (0 | 2, b'\r') => self.matched + 1
        (1 | 3, b'\n') => self.matched + 1
        _ => 0
      }
      if self.matched == 4 {
        let head = self.buffer.to_bytes()
        self.buffer.reset()
        self.complete = Some(head)
        return { head: Some(head), consumed: i + 1, }
      }
    }
    { head: None, consumed: bytes.length(), }
  } catch {
    error => {
      self.failure = Some(error)
      self.buffer.reset()
      raise error
    }
  }
}

///|
/// Returns a completed head or refuses an incomplete head at EOF.
pub fn HeadDecoder::finish(self : HeadDecoder) -> Bytes raise ParseError {
  if self.failure is Some(error) {
    raise error
  }
  match self.complete {
    Some(head) => head
    None => {
      let error = malformed("truncated head")
      self.failure = Some(error)
      self.buffer.reset()
      raise error
    }
  }
}

///|
fn field(line : String) -> (String, String) raise ParseError {
  guard line.find(":") is Some(colon) else {
    raise malformed("header lacks colon")
  }
  let name = line[:colon].to_owned()
  if !token(name) {
    raise malformed("invalid header name")
  }
  let raw = line[colon + 1:]
  if raw.iter().any(c => (c < ' ' && c != '\t') || c == '\u{7f}') {
    raise malformed("invalid header value")
  }
  // Only HTTP OWS is removed, never Unicode whitespace in obs-text.
  let mut start = 0
  let mut end = raw.length()
  while start < end && (raw[start] == ' ' || raw[start] == '\t') {
    start += 1
  }
  while end > start && (raw[end - 1] == ' ' || raw[end - 1] == '\t') {
    end -= 1
  }
  (name.to_lower(), raw[start:end].to_owned())
}

///|
fn head_lines(
  head : BytesView,
  limits : Limits,
) -> (String, @model.Headers) raise ParseError {
  guard scan_head(head, max=limits.max_head_bytes) is Some(end) &&
    end == head.length() else {
    raise malformed("expected exactly one complete head")
  }
  if limits.max_headers < 0 {
    raise malformed("negative header count")
  }
  let lines = latin1(head[:head.length() - 4]).split("\r\n")
  let first = lines.next().unwrap_or("")
  let pairs = []
  for line in lines {
    if pairs.length() >= limits.max_headers {
      raise ParseError(kind=HeadTooLarge, detail="too many headers")
    }
    pairs.push(field(line.to_owned()))
  }
  (first.to_owned(), @model.Headers::of(pairs))
}

///|
fn version(text : String) -> Version raise ParseError {
  match text {
    "HTTP/1.0" => Http10
    "HTTP/1.1" => Http11
    _ => raise ParseError(kind=Unsupported, detail="unsupported HTTP version")
  }
}

///|
/// Parses a strict request head, retaining duplicate fields. HTTP/1.1 needs
/// one nonempty valid Host. Framing validation is performed separately.
pub fn parse_request_head(
  head : BytesView,
  limits~ : Limits = Limits::default(),
) -> (@model.Method, String, Version, @model.Headers) raise ParseError {
  let (line, headers) = head_lines(head, limits)
  let parts = line.split(" ").collect()
  guard parts.length() == 3 && token(parts[0].to_owned()) else {
    raise malformed("invalid request line")
  }
  let target = parts[1].to_owned()
  if target.is_empty() ||
    target.iter().any(c => c <= ' ' || c >= '\u{7f}' || c == '#') {
    raise malformed("invalid request target")
  }
  let v = version(parts[2].to_owned())
  let meth = @model.Method::parse(parts[0].to_owned())
  validate_target(meth, target)
  if v == Http10 && headers.contains("transfer-encoding") {
    raise malformed("Transfer-Encoding on HTTP/1.0")
  }
  let hosts = headers.get_all("host")
  if hosts.length() > 1 || (v == Http11 && hosts.is_empty()) {
    raise malformed("expected one Host")
  }
  if hosts is [host] {
    if host.is_empty() ||
      host
      .iter()
      .any(c => c <= ' ' || c >= '\u{7f}' || "/\\@?#,".contains_char(c)) {
      raise malformed("invalid Host")
    }
    let parsed = @model.Url::parse("http://" + host) catch {
      _ => raise malformed("invalid Host")
    }
    if parsed.host is None || parsed.host == Some("") {
      raise malformed("invalid Host")
    }
  }
  (meth, target, v, headers)
}

///|
/// Parses a response head with exactly three status digits and a reason
/// phrase separated by SP. Duplicate fields and obs-text values are retained.
pub fn parse_response_head(
  head : BytesView,
  limits~ : Limits = Limits::default(),
) -> (Version, Int32, @model.Headers) raise ParseError {
  let (line, headers) = head_lines(head, limits)
  if line.length() < 13 || line[8] != ' ' || line[12] != ' ' {
    raise malformed("invalid status line")
  }
  let v = version(line[:8].to_owned())
  if v == Http10 && headers.contains("transfer-encoding") {
    raise malformed("Transfer-Encoding on HTTP/1.0")
  }
  let mut status = 0
  for c in line[9:12] {
    if c < '0' || c > '9' {
      raise malformed("invalid status code")
    }
    status = status * 10 + c.to_int() - '0'.to_int()
  }
  if status < 100 ||
    status > 599 ||
    line[13:].iter().any(c => (c < ' ' && c != '\t') || c == '\u{7f}') {
    raise malformed("invalid status line")
  }
  (v, status, headers)
}

///|
fn validate_target(
  meth : @model.Method,
  target : String,
) -> Unit raise ParseError {
  if target.contains("\\") {
    raise malformed("backslash in request target")
  }
  if meth == Connect {
    if target.iter().any(c => "/?#@".contains_char(c)) {
      raise malformed("CONNECT requires authority-form")
    }
    let url = @model.Url::parse("http://" + target) catch {
      _ => raise malformed("invalid CONNECT authority")
    }
    if url.host is None || url.host == Some("") || url.port is None {
      raise malformed("CONNECT requires host and port")
    }
  } else if target == "*" {
    if meth != Options {
      raise malformed("asterisk-form requires OPTIONS")
    }
  } else if !target.has_prefix("/") {
    let url = @model.Url::parse(target) catch {
      _ => raise malformed("invalid absolute target")
    }
    if !(url.scheme is Some("http" | "https")) ||
      url.host is None ||
      url.host == Some("") ||
      url.userinfo is Some(_) {
      raise malformed("expected origin-form or absolute HTTP target")
    }
  }
}

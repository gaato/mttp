///|
/// The end-of-head matcher shared by `scan_head` and `HeadDecoder`: it
/// refuses a bare CR or LF and reports the byte that completes CRLF CRLF.
/// While `leading`, CRLFs before the start line are skipped instead of
/// ending the head.
priv struct HeadScan {
  mut matched : Int32
  mut previous_cr : Bool
  mut leading : Bool
}

///|
fn HeadScan::new(skip_leading_crlf : Bool) -> HeadScan {
  { matched: 0, previous_cr: false, leading: skip_leading_crlf, }
}

///|
fn HeadScan::step(self : HeadScan, byte : Byte) -> Bool raise ParseError {
  if (self.previous_cr && byte != b'\n') || (byte == b'\n' && !self.previous_cr) {
    raise malformed("head requires CRLF line endings")
  }
  self.previous_cr = byte == b'\r'
  if self.leading {
    if byte is (b'\r' | b'\n') {
      return false
    }
    self.leading = false
  }
  self.matched = match (self.matched, byte) {
    (0 | 2, b'\r') => self.matched + 1
    (1 | 3, b'\n') => self.matched + 1
    _ => 0
  }
  self.matched == 4
}

///|
/// Finds the first complete head in `buf` within `max` bytes and returns its
/// exclusive end, or `None` while the head is incomplete and within `max`.
/// Refuses a bare CR or LF. With `skip_leading_crlf`, empty lines (CRLF)
/// before the start line are part of the head instead of ending it, and
/// count against `max`; a server reading requests sets it (RFC 9112,
/// section 2.2). Each call scans `buf` from the start; feed arriving input
/// to a `HeadDecoder` instead, which scans each byte once.
///
/// ```mbt check
/// test {
///   let wire = b"HTTP/1.1 204\r\n\r\nnext"
///   assert_eq(@h1.scan_head(wire, max=16384), Some(16))
///   assert_eq(@h1.scan_head(wire[:10], max=16384), None)
///   let request = b"\r\nGET / HTTP/1.1\r\nHost: h\r\n\r\n"
///   assert_eq(
///     @h1.scan_head(request, max=16384, skip_leading_crlf=true),
///     Some(request.length()),
///   )
/// }
/// ```
pub fn scan_head(
  buf : BytesView,
  max~ : Int32,
  skip_leading_crlf~ : Bool = false,
) -> Int32? raise ParseError {
  if max < 0 {
    raise malformed("negative head limit")
  }
  let scan = HeadScan::new(skip_leading_crlf)
  for i, byte in buf {
    if i >= max {
      raise too_large("head exceeds \{max} bytes")
    }
    if scan.step(byte) {
      return Some(i + 1)
    }
  }
  None
}

///|
/// The result of feeding a `HeadDecoder`: the head once it is complete, and
/// how many of the fed bytes it took. The bytes after `consumed` belong to
/// the body or to a pipelined message; the decoder never keeps them.
#derive(Eq, Debug)
pub struct HeadResult {
  /// The complete head, including its final CRLF CRLF.
  head : Bytes?
  /// How many bytes of this feed belong to the head.
  consumed : Int32
}

///|
/// Formats head decoder results.
pub extend HeadResult with @debug.Debug::{to_repr}

///|
/// Compares head decoder results.
pub extend HeadResult with Eq::{equal, not_equal}

///|
/// A bounded head accumulator that scans each byte once, so feeding a head
/// in any number of pieces costs linear time. After completion, later feeds
/// return the same head with zero bytes consumed. Errors are sticky: every
/// later `feed` or `finish` raises the first error again.
pub struct HeadDecoder {
  priv max : Int32
  priv mut seen : Int32
  priv buffer : Buffer
  priv scan : HeadScan
  priv mut complete : Bytes?
  priv mut failure : ParseError?
}

///|
/// Starts a head accumulator that refuses heads longer than `max` bytes,
/// final CRLF CRLF included (default 16 KiB, as `Limits::default`). With
/// `skip_leading_crlf`, empty lines (CRLF) before the start line are
/// consumed, left out of the returned head and counted against `max`, as a
/// server reading requests should (RFC 9112, section 2.2); a client reading
/// responses leaves it off, so a leading empty line is refused.
///
/// ```mbt check
/// test {
///   let decoder = @h1.HeadDecoder::new()
///   assert_eq(decoder.feed(b"HTTP/1.1 200 OK\r\n").consumed, 17)
///   let result = decoder.feed(b"\r\nbody")
///   assert_eq(result.consumed, 2)
///   assert_eq(result.head, Some(b"HTTP/1.1 200 OK\r\n\r\n"))
///   let requests = @h1.HeadDecoder::new(skip_leading_crlf=true)
///   let result = requests.feed(b"\r\nGET / HTTP/1.1\r\nHost: h\r\n\r\n")
///   assert_eq(result.consumed, 29)
///   assert_eq(result.head, Some(b"GET / HTTP/1.1\r\nHost: h\r\n\r\n"))
/// }
/// ```
pub fn HeadDecoder::new(
  max~ : Int32 = 16384,
  skip_leading_crlf~ : Bool = false,
) -> HeadDecoder {
  {
    max,
    seen: 0,
    buffer: Buffer(),
    scan: HeadScan::new(skip_leading_crlf),
    complete: None,
    failure: None,
  }
}

///|
fn HeadDecoder::fail(self : HeadDecoder, error : ParseError) -> ParseError {
  self.failure = Some(error)
  self.buffer.reset()
  error
}

///|
/// Takes the bytes of `bytes` that belong to the head, up to the decoder's
/// limit, and returns the head once its final CRLF CRLF arrived.
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
  if self.max < 0 {
    raise self.fail(malformed("negative head limit"))
  }
  for i, byte in bytes {
    // Skipped empty lines count too, so a peer cannot send them forever.
    if self.seen >= self.max {
      raise self.fail(too_large("head exceeds \{self.max} bytes"))
    }
    self.seen += 1
    let done = self.scan.step(byte) catch {
      ParseError(..) as error => raise self.fail(error)
    }
    if self.scan.leading {
      continue
    }
    self.buffer.write_byte(byte)
    if done {
      let head = self.buffer.to_bytes()
      self.buffer.reset()
      self.complete = Some(head)
      return { head: Some(head), consumed: i + 1, }
    }
  }
  { head: None, consumed: bytes.length(), }
}

///|
/// Returns the completed head at end of input, or refuses a truncated one.
pub fn HeadDecoder::finish(self : HeadDecoder) -> Bytes raise ParseError {
  if self.failure is Some(error) {
    raise error
  }
  match self.complete {
    Some(head) => head
    None => raise self.fail(malformed("truncated head"))
  }
}

///|
/// Splits one complete head into its start line and its fields, after
/// any empty lines `skip_leading_crlf` allows.
fn head_lines(
  head : BytesView,
  limits : Limits,
  skip_leading_crlf~ : Bool,
) -> (String, @mttp.Headers) raise ParseError {
  guard scan_head(head, max=limits.max_head_bytes, skip_leading_crlf~)
    is Some(end) &&
    end == head.length() else {
    raise malformed("expected exactly one complete head")
  }
  // Only skipped empty lines precede the start line, so this stops inside
  // the head.
  let mut start = 0
  while skip_leading_crlf && head[start] is (b'\r' | b'\n') {
    start += 1
  }
  if limits.max_headers < 0 {
    raise malformed("negative field limit")
  }
  // scan_head proved every CR is followed by LF and every LF preceded by CR,
  // so splitting on CRLF recovers the lines exactly.
  let lines = latin1(head[start:head.length() - 4]).split("\r\n")
  let first = lines.next().unwrap_or("")
  let pairs = []
  for line in lines {
    if pairs.length() >= limits.max_headers {
      raise too_large("more than \{limits.max_headers} fields")
    }
    pairs.push(field(line))
  }
  (first.to_owned(), @mttp.Headers::of(pairs))
}

///|
/// Reads `HTTP-version` (RFC 9112, section 2.3). The name is case
/// sensitive; a higher HTTP/1 minor version is read as HTTP/1.1, and another
/// major version is unsupported.
fn version(text : StringView) -> Version raise ParseError {
  match text {
    ['H', 'T', 'T', 'P', '/', '1', '.', '0'] => Http10
    ['H', 'T', 'T', 'P', '/', '1', '.', '1'..<='9'] => Http11
    ['H', 'T', 'T', 'P', '/', '0'..<='9', '.', '0'..<='9'] =>
      raise ParseError(kind=Unsupported, detail="unsupported HTTP version")
    _ => raise malformed("invalid HTTP version")
  }
}

///|
/// A recipient of HTTP/1.0 with Transfer-Encoding cannot trust its framing
/// (RFC 9112, section 6.1), and an HTTP/1.0 peer may frame it differently.
fn check_version_framing(
  v : Version,
  headers : @mttp.Headers,
) -> Unit raise ParseError {
  if v == Http10 && headers.contains("transfer-encoding") {
    raise ParseError(kind=Smuggling, detail="Transfer-Encoding on HTTP/1.0")
  }
}

///|
/// Parses a strict request head: one complete head within `limits` (empty
/// lines before the request line are skipped and counted), a request line of three parts separated by single spaces, a target of the
/// form its method requires, and at most one valid `Host`, which HTTP/1.1
/// requires. Fields keep their order and duplicates. Body framing is checked
/// separately by `request_framing`, except that Transfer-Encoding on HTTP/1.0
/// is refused here as smuggling.
///
/// ```mbt check
/// test {
///   let request = @h1.parse_request_head(
///     b"GET /items?page=2 HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\n\r\n",
///   )
///   assert_eq(request.meth, Get)
///   assert_eq(request.target, "/items?page=2")
///   assert_eq(request.version, Http11)
///   assert_eq(request.headers.get("host"), Some("example.com"))
/// }
/// ```
pub fn parse_request_head(
  head : BytesView,
  limits~ : Limits = Limits::default(),
) -> ParsedRequest raise ParseError {
  let (line, headers) = head_lines(head, limits, skip_leading_crlf=true)
  let parts = line.split(" ").collect()
  guard parts is [meth, target, v] && token(meth) else {
    raise malformed("invalid request line")
  }
  if target.is_empty() ||
    target.iter().any(c => c <= ' ' || c >= '\u{7f}' || c == '#') {
    raise malformed("invalid request target")
  }
  let version = version(v)
  let meth = @mttp.Method::parse(meth.to_owned())
  let target = target.to_owned()
  validate_target(meth, target)
  check_version_framing(version, headers)
  let hosts = headers.get_all("host")
  if hosts.length() > 1 || (version == Http11 && hosts.is_empty()) {
    raise malformed("expected one Host")
  }
  if hosts is [host] {
    validate_host(host)
  }
  { meth, target, version, headers, }
}

///|
/// A `Host` value is a bare authority (`uri-host [ ":" port ]`).
fn validate_host(host : String) -> Unit raise ParseError {
  if host.is_empty() ||
    host
    .iter()
    .any(c => c <= ' ' || c >= '\u{7f}' || "/\\@?#,".contains_char(c)) {
    raise malformed("invalid Host")
  }
  let parsed = @mttp.Url::parse("http://" + host) catch {
    _ => raise malformed("invalid Host")
  }
  if parsed.host is (None | Some("")) {
    raise malformed("invalid Host")
  }
}

///|
/// Checks the request-target form against the method (RFC 9112, section
/// 3.2): authority-form only for CONNECT, asterisk-form only for OPTIONS,
/// otherwise origin-form or an absolute http(s) URL without userinfo.
fn validate_target(
  meth : @mttp.Method,
  target : String,
) -> Unit raise ParseError {
  if target.contains("\\") {
    raise malformed("backslash in request target")
  }
  if meth == Connect {
    if target.iter().any(c => "/?#@".contains_char(c)) {
      raise malformed("CONNECT requires authority-form")
    }
    // An unknown scheme keeps every explicit port, including HTTP's 80.
    let url = @mttp.Url::parse("connect://" + target) catch {
      _ => raise malformed("invalid CONNECT authority")
    }
    if url.host is (None | Some("")) || url.port is None {
      raise malformed("CONNECT requires host and port")
    }
  } else if target == "*" {
    if meth != Options {
      raise malformed("asterisk-form requires OPTIONS")
    }
  } else if !target.has_prefix("/") {
    let url = @mttp.Url::parse(target) catch {
      _ => raise malformed("invalid absolute target")
    }
    if !(url.scheme is Some("http" | "https")) ||
      url.host is (None | Some("")) ||
      url.userinfo is Some(_) {
      raise malformed("expected origin-form or absolute HTTP target")
    }
  }
}

///|
/// Parses a strict response head: one complete head within `limits`, with
/// no empty line before it, and a status line of the version, a single space, three digits from 100 to 599
/// and an optional reason phrase after another space. A status line without
/// a reason phrase, with or without the space before it, is accepted
/// (RFC 9112, section 4). Fields keep their order, duplicates and obs-text.
///
/// ```mbt check
/// test {
///   let response = @h1.parse_response_head(
///     b"HTTP/1.1 200\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n",
///   )
///   assert_eq(response.status, 200)
///   assert_eq(response.headers.get_all("set-cookie"), ["a=1", "b=2"])
/// }
/// ```
pub fn parse_response_head(
  head : BytesView,
  limits~ : Limits = Limits::default(),
) -> ParsedResponse raise ParseError {
  let (line, headers) = head_lines(head, limits, skip_leading_crlf=false)
  guard line.length() >= 12 &&
    line[8] == ' ' &&
    (line.length() == 12 || line[12] == ' ') else {
    raise malformed("invalid status line")
  }
  let version = version(line[:8])
  let mut status = 0
  for c in line[9:12] {
    guard c is ('0'..<='9') else { raise malformed("invalid status code") }
    status = status * 10 + c.to_int() - '0'.to_int()
  }
  if status < 100 || status > 599 {
    raise malformed("status code out of range")
  }
  if !line[12:].iter().all(is_field_char) {
    raise malformed("invalid reason phrase")
  }
  check_version_framing(version, headers)
  { version, status, headers, }
}

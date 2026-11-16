///|
/// Received part metadata. Filenames are untrusted labels, never paths.
#derive(Debug)
pub(all) struct PartHead {
  name : String
  filename : String?
  content_type : String?
  headers : @mttp_core.Headers
}

///|
/// Formats received part metadata for debugging.
pub extend PartHead with @debug.Debug::{to_repr}

///|
priv enum ReadEvent {
  Head(PartHead)
  Data(Bytes)
  End
}

///|
priv struct Scanner {
  marker : Bytes
  max_parts : Int32
  max_headers : Int32
  max_total : Int32
  max_buffer : Int32
  pending : Array[Byte]
  mut state : Int32
  mut total : Int32
  mut parts : Int32
  mut failed : Bool
  mut padding : Bool
}

///|
fn parse_error(detail : String) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Protocol, phase=Body, detail~)
}

///|
fn too_large(limit : Int32) -> @mttp_core.TransportError {
  @mttp_core.TransportError(
    kind=TooLarge(limit~),
    phase=Body,
    detail="multipart resource bound exceeded",
  )
}

///|
fn Scanner::new(
  boundary : String,
  parts : Int32,
  headers : Int32,
  total : Int32,
  buffer : Int32,
) -> Scanner raise @mttp_core.TransportError {
  validate_boundary(boundary) catch {
    _ => raise parse_error("invalid boundary")
  }
  guard parts >= 0 && headers >= 0 && total >= 0 && buffer >= 78 else {
    raise parse_error("invalid multipart limits (buffer must be at least 78)")
  }
  {
    marker: @mttp_core.encode_utf8("\r\n--" + boundary),
    max_parts: parts,
    max_headers: headers,
    max_total: total,
    max_buffer: buffer,
    pending: [b'\r', b'\n'],
    state: 0,
    total: 0,
    parts: 0,
    failed: false,
    padding: false,
  }
}

///|
// 0 preamble, 1 headers, 2 payload, 3 epilogue. Only a possible
// delimiter line is retained in payload state, so long binary lines stream.
fn Scanner::byte(
  self : Scanner,
  byte : Byte,
) -> ReadEvent? raise @mttp_core.TransportError {
  guard !self.failed else { raise parse_error("parser failed") }
  self.failed = true
  if self.total == self.max_total {
    raise too_large(self.max_total)
  }
  self.total += 1
  let event = self.step(byte)
  self.failed = false
  event
}

///|
fn Scanner::step(
  self : Scanner,
  byte : Byte,
) -> ReadEvent? raise @mttp_core.TransportError {
  if self.state == 3 {
    return None
  }
  if self.state == 1 {
    if self.pending.length() == self.max_headers {
      raise too_large(self.max_headers)
    }
    self.pending.push(byte)
    let size = self.pending.length()
    if size >= 4 &&
      self.pending[size - 4] == b'\r' &&
      self.pending[size - 3] == b'\n' &&
      self.pending[size - 2] == b'\r' &&
      byte == b'\n' {
      let bytes = Bytes::from_array(self.pending)
      let head = parse_head(bytes[:bytes.length() - 4].to_owned())
      self.pending.clear()
      self.state = 2
      return Some(Head(head))
    }
    return None
  }
  if self.pending.length() == self.max_buffer {
    raise too_large(self.max_buffer)
  }
  self.pending.push(byte)
  // Once padding is recognized, more LWSP needs neither copying nor rescanning.
  if self.padding && (byte == b' ' || byte == b'\t') {
    return None
  }
  self.padding = false
  let output : Array[Byte] = []
  while !self.pending.is_empty() {
    let bytes = Bytes::from_array(self.pending)
    if bytes.length() < self.marker.length() && self.marker.has_prefix(bytes[:]) {
      break
    }
    if bytes.has_prefix(self.marker[:]) {
      let tail = bytes[self.marker.length():]
      let closing = tail.has_prefix(b"--"[:])
      let suffix = if closing { tail[2:] } else { tail }
      if tail == b"-"[:] {
        break
      }
      let mut i = 0
      while i < suffix.length() && (suffix[i] == b' ' || suffix[i] == b'\t') {
        i += 1
      }
      if i == suffix.length() || suffix[i:] == b"\r"[:] {
        self.padding = i == suffix.length() && i > 0
        break
      }
      if suffix[i:] == b"\r\n"[:] {
        self.pending.clear()
        if closing {
          self.state = 3
        } else {
          if self.parts == self.max_parts {
            raise too_large(self.max_parts)
          }
          self.parts += 1
          self.state = 1
        }
        return if (self.parts > 0 && self.state != 1) || self.parts > 1 {
          Some(End)
        } else {
          None
        }
      }
    }
    // A false delimiter with much padding must be released in one pass;
    // shifting the array once per byte would make hostile padding quadratic.
    let mut keep = (self.marker.length() - 1).min(self.pending.length() - 1)
    while keep > 0 && !self.marker.has_prefix(bytes[bytes.length() - keep:]) {
      keep -= 1
    }
    if self.state == 2 {
      output.push_iter(bytes[:bytes.length() - keep].iter())
    }
    self.pending.clear()
    self.pending.push_iter(bytes[bytes.length() - keep:].iter())
    break
  }
  if output.is_empty() {
    None
  } else {
    Some(Data(Bytes::from_array(output)))
  }
}

///|
fn Scanner::finish(
  self : Scanner,
) -> ReadEvent? raise @mttp_core.TransportError {
  guard !self.failed else { raise parse_error("parser failed") }
  if self.state == 3 {
    return None
  }
  // RFC 2046 permits a closing delimiter without a final CRLF.
  let bytes = Bytes::from_array(self.pending)
  let closing = self.marker + b"--"
  if self.state != 1 &&
    bytes.has_prefix(closing[:]) &&
    bytes[closing.length():].iter().all(b => b == b' ' || b == b'\t') {
    self.pending.clear()
    self.state = 3
    return if self.parts > 0 { Some(End) } else { None }
  }
  self.failed = true
  raise parse_error("missing final multipart boundary")
}

///|
// Extracts one MIME parameter, supporting quoted strings and quoted pairs.
// A duplicate requested parameter or malformed quoting is rejected.
fn parameter(
  value : String,
  name : String,
) -> String? raise @mttp_core.TransportError {
  let bytes = @mttp_core.encode_utf8(value)
  let mut i = 0
  while i < bytes.length() && bytes[i] != b';' {
    i += 1
  }
  let mut found : String? = None
  while i < bytes.length() {
    i += 1
    while i < bytes.length() && (bytes[i] == b' ' || bytes[i] == b'\t') {
      i += 1
    }
    let start = i
    while i < bytes.length() && bytes[i] != b'=' && bytes[i] != b';' {
      i += 1
    }
    guard i < bytes.length() && bytes[i] == b'=' else {
      raise parse_error("invalid MIME parameter")
    }
    let key = @utf8.decode_lossy(bytes[start:i])
      .trim(chars=" \t")
      .to_owned()
      .to_lower()
    guard !key.is_empty() && key.iter().all(is_parameter_token) else {
      raise parse_error("invalid MIME parameter name")
    }
    i += 1
    while i < bytes.length() && (bytes[i] == b' ' || bytes[i] == b'\t') {
      i += 1
    }
    let result : Array[Byte] = []
    if i < bytes.length() && bytes[i] == b'"' {
      i += 1
      while i < bytes.length() && bytes[i] != b'"' {
        if bytes[i] == b'\\' {
          i += 1
        }
        guard i < bytes.length() else {
          raise parse_error("invalid quoted pair")
        }
        result.push(bytes[i])
        i += 1
      }
      guard i < bytes.length() else {
        raise parse_error("unterminated parameter")
      }
      i += 1
      while i < bytes.length() && (bytes[i] == b' ' || bytes[i] == b'\t') {
        i += 1
      }
      guard i == bytes.length() || bytes[i] == b';' else {
        raise parse_error("invalid parameter suffix")
      }
    } else {
      while i < bytes.length() && bytes[i] != b';' {
        result.push(bytes[i])
        i += 1
      }
      let token = @utf8.decode_lossy(Bytes::from_array(result)[:])
        .trim(chars=" \t")
        .to_owned()
      guard !token.is_empty() && token.iter().all(is_parameter_token) else {
        raise parse_error("invalid MIME parameter token")
      }
      result.clear()
      result.push_iter(@mttp_core.encode_utf8(token).iter())
    }
    if key == name {
      guard found is None else { raise parse_error("duplicate MIME parameter") }
      found = Some(@utf8.decode_lossy(Bytes::from_array(result)[:]))
    }
  }
  found
}

///|
/// Reads and validates the required boundary parameter of a multipart/form-data
/// Content-Type, including quoted boundaries. Malformed headers raise Protocol.
pub fn parse_boundary(
  content_type : String,
) -> String raise @mttp_core.TransportError {
  guard content_type
    .split(";")
    .next()
    .unwrap_or("")
    .trim(chars=" \t")
    .to_owned()
    .to_lower() ==
    "multipart/form-data" else {
    raise parse_error("expected multipart/form-data")
  }
  guard parameter(content_type, "boundary") is Some(boundary) else {
    raise parse_error("missing multipart boundary")
  }
  validate_boundary(boundary) catch {
    _ => raise parse_error("invalid multipart boundary")
  }
  boundary
}

///|
fn is_parameter_token(c : Char) -> Bool {
  c > ' ' && c < '\u007f' && !"()<>@,;:\\\"/[]?=".contains(c.to_string())
}

///|
fn parse_head(bytes : Bytes) -> PartHead raise @mttp_core.TransportError {
  let text = @utf8.decode_lossy(bytes[:])
  let lines : Array[String] = []
  for line in text.split("\r\n") {
    if line.has_prefix(" ") || line.has_prefix("\t") {
      guard !lines.is_empty() else {
        raise parse_error("orphan folded part header")
      }
      let last = lines.length() - 1
      lines[last] = lines[last] + " " + line.trim(chars=" \t").to_owned()
    } else {
      lines.push(line.to_owned())
    }
  }
  let mut headers = @mttp_core.Headers::empty()
  for line in lines {
    guard line.split_once(":") is Some((name, value)) else {
      raise parse_error("invalid part header")
    }
    headers = headers.add(name.to_owned(), value.trim(chars=" \t").to_owned())
  }
  headers.validate() catch {
    _ => raise parse_error("invalid part headers")
  }
  guard headers.get_all("content-disposition") is [disposition] &&
    disposition
    .split(";")
    .next()
    .unwrap_or("")
    .trim(chars=" \t")
    .to_owned()
    .to_lower() ==
    "form-data" else {
    raise parse_error("expected form-data disposition")
  }
  guard parameter(disposition, "filename*") is None else {
    raise parse_error("filename* is forbidden by RFC 7578")
  }
  guard parameter(disposition, "name") is Some(name) else {
    raise parse_error("missing part name")
  }
  guard headers.get_all("content-type").length() <= 1 else {
    raise parse_error("duplicate part content type")
  }
  {
    name,
    filename: parameter(disposition, "filename"),
    content_type: headers.get("content-type"),
    headers,
  }
}

///|
/// A part body is valid until the next next_part call; unread data is skipped.
pub(all) struct ReadPart {
  head : PartHead
  body : &@mttp_core.BodyStream
}

///|
/// Owns a multipart source. Pull sequentially and close when stopping early.
pub struct MultipartReader {
  priv source : &@mttp_core.BodyStream
  priv scanner : Scanner
  priv mut chunk : Bytes
  priv mut offset : Int32
  priv mut generation : Int32
  priv mut active : Bool
  priv mut closed : Bool
}

///|
/// Limits: 256 parts, 16 KiB headers per part, 64 MiB wire bytes,
/// 64 KiB delimiter lookbehind (including transport padding).
pub fn MultipartReader::new(
  source : &@mttp_core.BodyStream,
  boundary : String,
  max_parts~ : Int32 = 256,
  max_header_bytes~ : Int32 = 16384,
  max_total_bytes~ : Int32 = 67108864,
  max_buffer_bytes~ : Int32 = 65536,
) -> MultipartReader raise @mttp_core.TransportError {
  errdefer source.close()
  let scanner = Scanner::new(
    boundary, max_parts, max_header_bytes, max_total_bytes, max_buffer_bytes,
  )
  {
    source,
    scanner,
    chunk: b"",
    offset: 0,
    generation: 0,
    active: false,
    closed: false,
  }
}

///|
async fn MultipartReader::event(
  self : MultipartReader,
) -> ReadEvent? raise @mttp_core.TransportError {
  errdefer self.close()
  while !self.closed {
    if self.offset == self.chunk.length() {
      match self.source.read_some() {
        Some(chunk) => {
          self.chunk = chunk
          self.offset = 0
        }
        None => {
          let event = self.scanner.finish()
          self.close()
          return event
        }
      }
    }
    let byte = self.chunk[self.offset]
    self.offset += 1
    if self.scanner.byte(byte) is Some(event) {
      return Some(event)
    }
  }
  None
}

///|
/// Reads the next headers, discarding any unread previous payload.
/// EOF, failure and cancellation release the source once.
pub async fn MultipartReader::next_part(
  self : MultipartReader,
) -> ReadPart? raise @mttp_core.TransportError {
  errdefer self.close()
  self.generation += 1
  self.active = false
  while self.event() is Some(event) {
    if event is Head(head) {
      self.active = true
      return Some({
        head,
        body: PartStream::{
          reader: self,
          generation: self.generation,
          closed: false,
        },
      })
    }
  }
  None
}

///|
/// Releases the source once. Later reader and part-body pulls return EOF.
pub fn MultipartReader::close(self : MultipartReader) -> Unit {
  if !self.closed {
    self.closed = true
    self.active = false
    self.chunk = b""
    self.scanner.pending.clear()
    self.source.close()
  }
}

///|
priv struct PartStream {
  reader : MultipartReader
  generation : Int32
  mut closed : Bool
}

///|
impl @mttp_core.BodyStream for PartStream with fn read_some(self) {
  let reader = self.reader
  if self.closed || self.generation != reader.generation || !reader.active {
    return None
  }
  let output = Buffer()
  while reader.event() is Some(event) {
    match event {
      Data(bytes) => {
        output.write_bytes(bytes)
        if reader.offset == reader.chunk.length() || output.length() >= 65536 {
          return Some(output.to_bytes())
        }
      }
      End => {
        reader.active = false
        break
      }
      Head(_) => raise parse_error("unexpected part head")
    }
  }
  if output.length() == 0 {
    None
  } else {
    Some(output.to_bytes())
  }
}

///|
impl @mttp_core.BodyStream for PartStream with fn close(self) {
  self.closed = true
}

///|
/// Synchronous bounded decoding for buffered endpoint inputs; preserves order
/// and duplicate names. Streaming consumers should use MultipartReader.
pub fn parse(
  bytes : Bytes,
  boundary : String,
  max_parts~ : Int32 = 256,
  max_header_bytes~ : Int32 = 16384,
  max_total_bytes~ : Int32 = 67108864,
  max_part_bytes~ : Int32 = 16777216,
  max_buffer_bytes~ : Int32 = 65536,
) -> Array[Part] raise @mttp_core.TransportError {
  if max_part_bytes < 0 {
    raise parse_error("negative multipart part limit")
  }
  let scanner = Scanner::new(
    boundary, max_parts, max_header_bytes, max_total_bytes, max_buffer_bytes,
  )
  let parts : Array[Part] = []
  let mut head : PartHead? = None
  let body : Array[Byte] = []
  let receive = fn(event : ReadEvent) raise @mttp_core.TransportError {
    match event {
      Head(h) => head = Some(h)
      Data(chunk) => {
        if chunk.length() > max_part_bytes - body.length() {
          raise too_large(max_part_bytes)
        }
        body.push_iter(chunk.iter())
      }
      End =>
        if head is Some(h) {
          parts.push({
            name: h.name,
            filename: h.filename,
            content_type: h.content_type,
            body: Bytes(Bytes::from_array(body)),
          })
          head = None
          body.clear()
        }
    }
  }
  for byte in bytes {
    if scanner.byte(byte) is Some(event) {
      receive(event)
    }
  }
  if scanner.finish() is Some(event) {
    receive(event)
  }
  parts
}

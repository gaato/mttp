///|
/// A single multipart/form-data field with an optional filename and media
/// type. Its body is bytes, or a stream read as the request is sent
/// (`Part::file_stream`).
#derive(Eq, Debug)
pub(all) struct Part {
  name : String
  filename : String?
  content_type : String?
  body : @mttp_core.Body
}

///|
/// Compares every part field, including the body bytes.
pub extend Part with Eq::{equal, not_equal}

///|
/// Formats a part for debugging.
pub extend Part with @debug.Debug::{to_repr}

///|
/// Creates a UTF-8 text field without a content type.
///
/// ```mbt check
/// test {
///   assert_eq(@multipart.Part::text("message", "hello").body, Bytes(b"hello"))
/// }
/// ```
pub fn Part::text(name : String, value : String) -> Part {
  {
    name,
    filename: None,
    content_type: None,
    body: Bytes(@mttp_core.encode_utf8(value)),
  }
}

///|
/// Creates a file field, preserving the supplied body bytes exactly.
///
/// ```mbt check
/// test {
///   let part = @multipart.Part::file(
///     "upload", "data.bin", "application/octet-stream", b"\x00\xFF",
///   )
///   assert_eq(part.filename, Some("data.bin"))
///   assert_eq(part.body, Bytes(b"\x00\xFF"))
/// }
/// ```
pub fn Part::file(
  name : String,
  filename : String,
  content_type : String,
  body : Bytes,
) -> Part {
  {
    name,
    filename: Some(filename),
    content_type: Some(content_type),
    body: Bytes(body),
  }
}

///|
/// Creates a file field whose body is read from `stream` as the request is
/// sent, so the file need not be held in memory. With `length`, the stream
/// must produce exactly that many bytes; when every part's length is known,
/// the multipart body is sent with `Content-Length`, otherwise chunked. The
/// part can be sent once, like any stream body (`@mttp_core.StreamBody`).
pub fn Part::file_stream(
  name : String,
  filename : String,
  content_type : String,
  stream : &@mttp_core.BodyStream,
  length? : Int64,
) -> Part {
  {
    name,
    filename: Some(filename),
    content_type: Some(content_type),
    body: Stream(@mttp_core.StreamBody::new(stream, length?)),
  }
}

///|
/// Creates a JSON field encoded as UTF-8 with content type application/json.
///
/// ```mbt check
/// test {
///   let part = @multipart.Part::json("metadata", { "ok": true })
///   assert_eq(part.content_type, Some("application/json"))
///   assert_eq(part.body, Bytes(b"{\"ok\":true}"))
/// }
/// ```
pub fn Part::json(name : String, value : Json) -> Part {
  {
    name,
    filename: None,
    content_type: Some("application/json"),
    body: Bytes(@mttp_core.encode_utf8(value.stringify())),
  }
}

///|
/// Multipart validation and encoding failures, raised before any byte of the
/// body is produced.
#derive(Debug)
pub(all) suberror MultipartError {
  /// The boundary is empty, longer than 70 characters, ends with a space or
  /// holds a character outside RFC 2046's `bchars`.
  InvalidBoundary(String)
  /// An in-memory part body contains the delimiter `--boundary` at its start
  /// or after a CRLF.
  BoundaryCollision
  /// A part's content type holds a control character other than horizontal
  /// tab, so it could break the part's header block.
  InvalidHeaderValue(String)
  /// The named part is a stream, which `encode` and `encode_segments` cannot
  /// hold: use `encode_body` or `body`. Also rejects future body variants
  /// which this version of the multipart writer cannot represent.
  StreamPart(String)
}

///|
/// Formats a multipart failure for debugging.
pub extend MultipartError with @debug.Debug::{to_repr}

///|
/// A character RFC 2046 §5.1.1 allows in a boundary (`bchars`), which RFC 7578
/// §4.1 uses for multipart/form-data.
fn is_boundary_char(c : Char) -> Bool {
  c.is_ascii_alphabetic() ||
  c.is_ascii_digit() ||
  (match c {
    '\''
    | '('
    | ')'
    | '+'
    | '_'
    | ','
    | '-'
    | '.'
    | '/'
    | ':'
    | '='
    | '?'
    | ' ' => true
    _ => false
  })
}

///|
fn boundary_needs_quotes(boundary : String) -> Bool {
  boundary
  .iter()
  .any(c => {
    match c {
      '(' | ')' | ',' | '/' | ':' | '=' | '?' | ' ' => true
      _ => false
    }
  })
}

///|
fn validate_boundary(boundary : String) -> Unit raise MultipartError {
  if boundary.length() == 0 ||
    boundary.length() > 70 ||
    boundary.iter().any(c => !is_boundary_char(c)) ||
    boundary.has_suffix(" ") {
    raise InvalidBoundary(boundary)
  }
}

///|
fn append_bytes(output : Array[Byte], bytes : Bytes) -> Unit {
  output.push_iter(bytes.iter())
}

///|
fn append_text(output : Array[Byte], text : String) -> Unit {
  append_bytes(output, @mttp_core.encode_utf8(text))
}

///|
/// Writes a `name` or `filename` parameter value as the WHATWG HTML
/// multipart/form-data encoding algorithm does: `"`, CR and LF become `%22`,
/// `%0D` and `%0A`, which RFC 7578 §4.2 leaves to the sender.
fn append_escaped_parameter(output : Array[Byte], value : String) -> Unit {
  for byte in @mttp_core.encode_utf8(value) {
    match byte.to_int() {
      34 => append_bytes(output, b"%22")
      13 => append_bytes(output, b"%0D")
      10 => append_bytes(output, b"%0A")
      _ => output.push(byte)
    }
  }
}

///|
/// A character a part's header value may hold: anything but a control other
/// than horizontal tab, as `@mttp_core.Headers::validate` requires of request
/// headers. CR and LF would end the header line early and NUL is refused by
/// receivers. Non-ASCII text is written as UTF-8.
fn is_field_value_char(c : Char) -> Bool {
  !((c < ' ' && c != '\t') || c == '\u007f')
}

///|
fn body_collides(body : Bytes, delimiter : Bytes, embedded : Bytes) -> Bool {
  body.has_prefix(delimiter[:]) || body.find(embedded[:]) is Some(_)
}

///|
/// Encodes fields as multipart/form-data and returns its Content-Type value and
/// byte-exact body. A stream part raises `StreamPart`: see `encode_body`.
///
/// ```mbt check
/// test {
///   let (content_type, body) = @multipart.encode(
///     [@multipart.Part::text("message", "hello")],
///     "example",
///   )
///   assert_eq(content_type, "multipart/form-data; boundary=example")
///   assert_true(body.has_suffix(b"--example--\r\n"[:]))
/// }
/// ```
pub fn encode(
  parts : Array[Part],
  boundary : String,
) -> (String, Bytes) raise MultipartError {
  let (content_type, segments) = encode_segments(parts, boundary)
  let output : Array[Byte] = []
  for segment in segments {
    append_bytes(output, segment)
  }
  (content_type, Bytes::from_array(output))
}

///|
/// Encodes fields like `encode`, but returns the body as ordered segments
/// instead of one buffer: the framing between parts, and each part's body
/// exactly as supplied, not copied. The segments concatenated are the body
/// `encode` returns, so a host can stream a large upload without building it
/// in memory first. A stream part raises `StreamPart`.
///
/// ```mbt check
/// test {
///   let file = b"\x00\x01"
///   let (_, segments) = @multipart.encode_segments(
///     [@multipart.Part::file("upload", "a.bin", "application/octet-stream", file)],
///     "example",
///   )
///   assert_eq(segments.length(), 3)
///   assert_true(physical_equal(segments[1], file))
/// }
/// ```
pub fn encode_segments(
  parts : Array[Part],
  boundary : String,
) -> (String, Array[Bytes]) raise MultipartError {
  let (content_type, pieces) = layout(parts, boundary)
  let segments = pieces.map(piece => {
    match piece {
      Fixed(bytes) => bytes
      Streamed(name, _) => raise StreamPart(name)
    }
  })
  (content_type, segments)
}

///|
/// Encodes fields as a request body: the bytes `encode` returns when every
/// part is in memory, and otherwise a stream that reads each stream part as
/// it is sent. The stream has a known length, so a transport sends
/// `Content-Length`, only when every stream part was given one.
///
/// A stream part cannot be checked for the boundary before it is sent, so
/// each is scanned as it streams: one that contains the delimiter fails the
/// request with `TransportError(Protocol)` in phase Body before the colliding
/// bytes go out. With `make_boundary`'s 165 random bits a collision is not
/// expected; the scan makes it an error instead of a corrupt body.
///
/// ```mbt check
/// test {
///   let (_, body) = @multipart.encode_body(
///     [@multipart.Part::text("message", "hello")],
///     "B",
///   )
///   assert_eq(body.length(), Some(69L))
/// }
/// ```
pub fn encode_body(
  parts : Array[Part],
  boundary : String,
) -> (String, @mttp_core.Body) raise MultipartError {
  let (content_type, pieces) = layout(parts, boundary)
  (content_type, pieces_body(pieces, boundary))
}

///|
/// One stretch of an encoded body: framing and in-memory part bodies, or a
/// stream part's body with its part's name.
priv enum Piece {
  Fixed(Bytes)
  Streamed(String, @mttp_core.StreamBody)
}

///|
/// Validates `parts` and `boundary` and lays the body out as pieces. Bytes
/// parts are checked for the boundary here; stream parts as they stream.
fn layout(
  parts : Array[Part],
  boundary : String,
) -> (String, Array[Piece]) raise MultipartError {
  validate_boundary(boundary)
  let delimiter = @mttp_core.encode_utf8("--" + boundary)
  let embedded = @mttp_core.encode_utf8("\r\n--" + boundary)
  for part in parts {
    if part.content_type is Some(content_type) &&
      !content_type.iter().all(is_field_value_char) {
      raise InvalidHeaderValue(content_type)
    }
    if part.body is Bytes(body) && body_collides(body, delimiter, embedded) {
      raise BoundaryCollision
    }
  }
  let pieces : Array[Piece] = []
  let framing : Array[Byte] = []
  for part in parts {
    append_text(framing, "--" + boundary + "\r\n")
    append_text(framing, "Content-Disposition: form-data; name=\"")
    append_escaped_parameter(framing, part.name)
    append_text(framing, "\"")
    if part.filename is Some(filename) {
      append_text(framing, "; filename=\"")
      append_escaped_parameter(framing, filename)
      append_text(framing, "\"")
    }
    append_text(framing, "\r\n")
    if part.content_type is Some(content_type) {
      append_text(framing, "Content-Type: " + content_type + "\r\n")
    }
    append_text(framing, "\r\n")
    match part.body {
      Empty => ()
      Bytes(body) if body.is_empty() => ()
      Bytes(body) => {
        pieces.push(Fixed(Bytes::from_array(framing)))
        framing.clear()
        pieces.push(Fixed(body))
      }
      Stream(stream) => {
        pieces.push(Fixed(Bytes::from_array(framing)))
        framing.clear()
        pieces.push(Streamed(part.name, stream))
      }
      @mttp_core.Body::.. => raise StreamPart(part.name)
    }
    append_text(framing, "\r\n")
  }
  append_text(framing, "--" + boundary + "--\r\n")
  pieces.push(Fixed(Bytes::from_array(framing)))
  let parameter = if boundary_needs_quotes(boundary) {
    "\"" + boundary + "\""
  } else {
    boundary
  }
  ("multipart/form-data; boundary=" + parameter, pieces)
}

///|
/// Creates a 37-character boundary, `mttp-` and 32 base-36 random digits
/// (about 165 bits when `random` is uniform).
/// Values outside the random function's `[0, 1)` contract are clamped.
///
/// ```mbt check
/// test {
///   assert_eq(
///     @multipart.make_boundary(() => 0.0),
///     "mttp-00000000000000000000000000000000",
///   )
/// }
/// ```
pub fn make_boundary(random : () -> Double) -> String {
  let alphabet = b"0123456789abcdefghijklmnopqrstuvwxyz"
  let result = StringBuilder()
  result.write_string("mttp-")
  for _ in 0..<32 {
    let value = random()
    let index = if value.is_nan() || value <= 0.0 {
      0
    } else if value >= 1.0 {
      35
    } else {
      (value * 36.0).floor().to_int()
    }
    result.write_char(alphabet[index].to_char())
  }
  result.to_string()
}

///|
/// Returns an independent request with an encoded multipart body
/// (`encode_body`) and replaces every existing Content-Type value.
///
/// ```mbt check
/// test {
///   let request = @mttp_core.Request::post("/upload").header("x-id", "42")
///   let result = @multipart.body(
///     request,
///     [@multipart.Part::text("message", "hello")],
///     boundary="example",
///   )
///   assert_eq(
///     result.headers.get("content-type"),
///     Some("multipart/form-data; boundary=example"),
///   )
///   assert_eq(request.headers.get("content-type"), None)
/// }
/// ```
pub fn body(
  request : @mttp_core.Request,
  parts : Array[Part],
  boundary~ : String,
) -> @mttp_core.Request raise MultipartError {
  let (content_type, body) = encode_body(parts, boundary)
  let headers = request.headers.set("content-type", content_type)
  { ..request, headers, body, }
}

///|
/// Encodes with a fresh random boundary, retrying only BoundaryCollision up to
/// `attempts` draws. Nonpositive attempts raise BoundaryCollision without drawing.
pub fn encode_segments_fresh(
  parts : Array[Part],
  random~ : () -> Double,
  attempts~ : Int32 = 16,
) -> (String, Array[Bytes]) raise MultipartError {
  for _ in 0..<attempts {
    let boundary = make_boundary(random)
    try encode_segments(parts, boundary) catch {
      BoundaryCollision => continue
      other => raise other
    } noraise {
      result => return result
    }
  }
  raise BoundaryCollision
}

///|
/// Joins encoded segments into one buffer, preserving their order.
pub fn join_segments(segments : Array[Bytes]) -> Bytes {
  let size = segments.fold(init=0, (size, segment) => size + segment.length())
  let buffer = Buffer(size_hint=size)
  for segment in segments {
    buffer.write_bytes(segment)
  }
  buffer.to_bytes()
}

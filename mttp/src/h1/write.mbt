///|
/// Validates every outgoing field, then replaces Content-Length and
/// Transfer-Encoding with the ones `framing` implies. `NoBody` writes
/// `Content-Length: 0` when `empty_length`: where a recipient would
/// otherwise read until close, or where the method anticipates content.
fn wire_fields(
  headers : @mttp.Headers,
  framing : Framing,
  v : Version,
  empty_length~ : Bool,
) -> @mttp.Headers raise ParseError {
  // Fields replaced below are validated too: a framing override must not
  // hide a malformed value the caller supplied.
  for (name, value) in headers.iter() {
    if !token(name) ||
      !value.iter().all(c => is_field_char(c) && c.to_int() <= 0xff) {
      raise malformed("invalid outgoing field \{name}")
    }
  }
  let headers = headers.remove("content-length").remove("transfer-encoding")
  match framing {
    NoBody if empty_length => headers.add("content-length", "0")
    NoBody => headers
    Length(n) => {
      if n < 0L {
        raise malformed("negative body length")
      }
      headers.add("content-length", n.to_string())
    }
    Chunked => {
      if v == Http10 {
        raise ParseError(kind=Unsupported, detail="HTTP/1.0 cannot be chunked")
      }
      headers.add("transfer-encoding", "chunked")
    }
    UntilClose => headers.set("connection", "close")
  }
}

///|
fn version_text(v : Version) -> String {
  match v {
    Http10 => "HTTP/1.0"
    Http11 => "HTTP/1.1"
  }
}

///|
/// Writes the start line and the fields; values are written as Latin-1
/// octets, the inverse of the parser's decoding.
fn head_bytes(start : String, headers : @mttp.Headers) -> Bytes {
  let buffer = Buffer()
  buffer.write_bytes(@mttp.encode_utf8(start + "\r\n"))
  for (name, value) in headers.iter() {
    buffer.write_bytes(@mttp.encode_utf8(name + ": "))
    for c in value {
      buffer.write_byte(c.to_int().to_byte())
    }
    buffer.write_bytes(b"\r\n")
  }
  buffer.write_bytes(b"\r\n")
  buffer.to_bytes()
}

///|
/// Serializes a response to `meth` with the standard reason phrase,
/// replacing Content-Length and Transfer-Encoding with the ones `framing`
/// implies, so that `response_framing` reads back the same body:
///
/// - `NoBody` on a status that has a body writes `Content-Length: 0`, on
///   HTTP/1.0 too, since a response without either field is read until
///   close. A response that never has a body (to HEAD, a 1xx, 204 or 304, a
///   2xx to CONNECT) gets no framing field.
/// - `Length(n)` and `Chunked` on a response to HEAD or a 304 describe the
///   body a GET would have had (RFC 9110, sections 8.6 and 15.4.5); no body
///   follows either way.
/// - `UntilClose` adds `Connection: close`.
///
/// Refuses a status outside 100 to 599, body framing on a 1xx, 204 or 2xx to
/// CONNECT (RFC 9110, section 9.3.6), a negative length, chunked HTTP/1.0
/// and invalid fields. Values are written as Latin-1 octets, matching the
/// parser; encode text beyond Latin-1 before putting it in a field. No body
/// bytes are written.
///
/// ```mbt check
/// test {
///   let head = @h1.write_response_head(
///     200,
///     @mttp.Headers::of([("Content-Type", "text/plain")]),
///     Length(5),
///     Http11,
///   )
///   assert_eq(
///     head, b"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 5\r\n\r\n",
///   )
///   let empty = @h1.write_response_head(
///     200,
///     @mttp.Headers::empty(),
///     NoBody,
///     Http11,
///   )
///   assert_eq(empty, b"HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
///   let none = @h1.write_response_head(
///     204,
///     @mttp.Headers::empty(),
///     NoBody,
///     Http11,
///   )
///   assert_eq(none, b"HTTP/1.1 204 No Content\r\n\r\n")
/// }
/// ```
pub fn write_response_head(
  status : Int32,
  headers : @mttp.Headers,
  framing : Framing,
  v : Version,
  meth~ : @mttp.Method = Get,
) -> Bytes raise ParseError {
  if status < 100 || status > 599 {
    raise malformed("invalid status code")
  }
  if (
      status / 100 == 1 ||
      status == 204 ||
      (meth == Connect && status / 100 == 2)
    ) &&
    framing != NoBody {
    raise malformed("status prohibits body framing")
  }
  let headers = wire_fields(
    headers,
    framing,
    v,
    empty_length=!has_no_body(status, meth),
  )
  head_bytes(
    "\{version_text(v)} \{status} \{@mttp.reason_phrase(status)}",
    headers,
  )
}

///|
/// Serializes a request head, replacing Content-Length and Transfer-Encoding
/// with the ones `framing` implies, and keeping duplicate fields. `NoBody`
/// writes `Content-Length: 0` for POST, PUT and PATCH, whose semantics
/// anticipate content, and no framing field for other methods (RFC 9110,
/// section 8.6); pass `Length(0)` to send it for another method. The result
/// passes the same checks as `parse_request_head` (target form, Host), and a
/// request cannot be `UntilClose`. No body bytes are written.
///
/// ```mbt check
/// test {
///   let head = @h1.write_request_head(
///     Post,
///     "/items",
///     @mttp.Headers::of([("Host", "example.com")]),
///     Chunked,
///     Http11,
///   )
///   assert_eq(
///     head, b"POST /items HTTP/1.1\r\nhost: example.com\r\ntransfer-encoding: chunked\r\n\r\n",
///   )
/// }
/// ```
pub fn write_request_head(
  meth : @mttp.Method,
  target : String,
  headers : @mttp.Headers,
  framing : Framing,
  v : Version,
) -> Bytes raise ParseError {
  if framing == UntilClose {
    raise malformed("a request cannot be close-delimited")
  }
  let headers = wire_fields(
    headers,
    framing,
    v,
    empty_length=meth is (Post | Put | Patch),
  )
  let head = head_bytes("\{meth} \{target} \{version_text(v)}", headers)
  let _ = parse_request_head(head, limits={
    ..Limits::default(),
    max_head_bytes: head.length(),
    max_headers: headers.length(),
  })
  head
}

///|
/// Encodes one chunk of the chunked coding; an empty `bytes` encodes the
/// last chunk with an empty trailer section, which ends the body.
///
/// ```mbt check
/// test {
///   assert_eq(@h1.encode_chunk(b"Wiki"), b"4\r\nWiki\r\n")
///   assert_eq(@h1.encode_chunk(b""), b"0\r\n\r\n")
/// }
/// ```
pub fn encode_chunk(bytes : BytesView) -> Bytes {
  let buffer = Buffer()
  buffer.write_bytes(
    @mttp.encode_utf8(bytes.length().to_string(radix=16) + "\r\n"),
  )
  buffer.write_bytesview(bytes)
  buffer.write_bytes(b"\r\n")
  buffer.to_bytes()
}

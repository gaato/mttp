///|
fn wire_fields(
  headers : @model.Headers,
  framing : Framing,
  v : Version,
) -> @model.Headers raise ParseError {
  // Validate even fields replaced below: callers must not hide malformed
  // values behind a framing override.
  for (name, value) in headers.iter() {
    if !token(name) ||
      value
      .iter()
      .any(c => (c < ' ' && c != '\t') || c == '\u{7f}' || c.to_int() > 255) {
      raise malformed("invalid outgoing field")
    }
  }
  let headers = headers.remove("content-length").remove("transfer-encoding")
  match framing {
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
fn head_bytes(start : String, headers : @model.Headers) -> Bytes {
  let buffer = Buffer()
  buffer.write_bytes(@model.encode_utf8(start + "\r\n"))
  for (name, value) in headers.iter() {
    buffer.write_bytes(@model.encode_utf8(name + ": "))
    for c in value {
      buffer.write_byte(c.to_int().to_byte())
    }
    buffer.write_bytes(b"\r\n")
  }
  buffer.write_bytes(b"\r\n")
  buffer.to_bytes()
}

///|
/// Serializes a response head, replacing CL/TE with the selected framing.
/// Refuses invalid fields/status, negative lengths and chunked HTTP/1.0.
/// Values use Latin-1 octets, matching the parser; callers must encode any
/// non-Latin-1 application text explicitly. No body bytes are emitted.
pub fn write_response_head(
  status : Int32,
  headers : @model.Headers,
  framing : Framing,
  v : Version,
) -> Bytes raise ParseError {
  if status < 100 || status > 599 {
    raise malformed("invalid status code")
  }
  if (status / 100 == 1 || status == 204) && framing != NoBody {
    raise malformed("status prohibits body framing")
  }
  let headers = wire_fields(headers, framing, v)
  head_bytes(
    version_text(v) +
    " " +
    status.to_string() +
    " " +
    @model.reason_phrase(status),
    headers,
  )
}

///|
/// Serializes a request target already derived from a validated URL, retaining
/// duplicate fields. A request cannot use close-delimited body framing.
/// Host/target checks are the same as parse_request_head.
pub fn write_request_head(
  meth : @model.Method,
  target : String,
  headers : @model.Headers,
  framing : Framing,
  v : Version,
) -> Bytes raise ParseError {
  if framing == UntilClose {
    raise malformed("request cannot be close-delimited")
  }
  let headers = wire_fields(headers, framing, v)
  let head = head_bytes(
    meth.to_string() + " " + target + " " + version_text(v),
    headers,
  )
  let _ = parse_request_head(head, limits={
    ..Limits::default(),
    max_head_bytes: head.length(),
    max_headers: headers.length(),
  })
  head
}

///|
/// Encodes a nonempty data chunk, or the final empty chunk with no trailers.
pub fn encode_chunk(bytes : Bytes) -> Bytes {
  let buffer = Buffer()
  buffer.write_bytes(
    @model.encode_utf8(bytes.length().to_string(radix=16) + "\r\n"),
  )
  buffer.write_bytes(bytes)
  buffer.write_bytes(b"\r\n")
  buffer.to_bytes()
}

///|
fn framing_fields(headers : @model.Headers) -> Framing? raise ParseError {
  let lengths = headers.get_all("content-length")
  let encodings = headers.get_all("transfer-encoding")
  if !lengths.is_empty() && !encodings.is_empty() {
    raise ParseError(
      kind=Smuggling,
      detail="Content-Length with Transfer-Encoding",
    )
  }
  if lengths.length() > 1 {
    raise malformed("duplicate Content-Length")
  }
  if lengths is [value] {
    let value = ows(value)
    if value.is_empty() {
      raise malformed("empty Content-Length")
    }
    let mut length = 0L
    for c in value {
      if c < '0' || c > '9' {
        raise malformed("invalid Content-Length")
      }
      let digit = (c.to_int() - '0'.to_int()).to_int64()
      if length > (9223372036854775807L - digit) / 10L {
        raise malformed("Content-Length overflow")
      }
      length = length * 10L + digit
    }
    return Some(Length(length))
  }
  if !encodings.is_empty() {
    let codings = []
    for value in encodings {
      for part in value.split(",") {
        let coding = ows(part.to_owned()).to_lower()
        if coding.is_empty() {
          raise malformed("empty transfer coding")
        }
        codings.push(coding)
      }
    }
    if codings.filter(c => c == "chunked").length() > 1 {
      raise malformed("duplicate chunked coding")
    }
    if codings == ["chunked"] {
      return Some(Chunked)
    }
    raise ParseError(kind=Unsupported, detail="unsupported transfer coding")
  }
  None
}

///|
/// Resolves request framing, rejecting CL+TE, duplicate/invalid lengths and
/// every transfer coding except a single chunked. An absent length is empty.
pub fn request_framing(headers : @model.Headers) -> Framing raise ParseError {
  framing_fields(headers).unwrap_or(NoBody)
}

///|
/// Resolves response framing after validating length/coding fields. HEAD,
/// 1xx, 204, 304 and successful CONNECT have no HTTP message body. CONNECT
/// callers must separately hand off the remaining bytes to the tunnel.
pub fn response_framing(
  headers : @model.Headers,
  status~ : Int32,
  meth~ : @model.Method = Get,
) -> Framing raise ParseError {
  let framing = framing_fields(headers)
  if meth == Head ||
    status / 100 == 1 ||
    status == 204 ||
    status == 304 ||
    (meth == Connect && status / 100 == 2) {
    return NoBody
  }
  framing.unwrap_or(UntilClose)
}

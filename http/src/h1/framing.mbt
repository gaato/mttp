///|
/// Resolves Content-Length and Transfer-Encoding, or `None` when neither is
/// present (RFC 9112, section 6).
fn framing_fields(headers : @http.Headers) -> Framing? raise ParseError {
  let lengths = headers.get_all("content-length")
  let encodings = headers.get_all("transfer-encoding")
  if !lengths.is_empty() && !encodings.is_empty() {
    raise ParseError(
      kind=Smuggling,
      detail="Content-Length with Transfer-Encoding",
    )
  }
  // Stricter than RFC 9112, section 6.3, which lets a recipient accept a list
  // or repetition of one identical value: any repetition is refused.
  if lengths.length() > 1 {
    raise malformed("duplicate Content-Length")
  }
  if lengths is [value] {
    return Some(Length(content_length(value)))
  }
  if encodings.is_empty() {
    return None
  }
  let codings = []
  for value in encodings {
    for part in value.split(",") {
      let coding = ows(part).to_lower()
      // Empty list elements are refused rather than skipped, so no
      // reading of `chunked,` or `, chunked` can differ between parsers.
      if coding.is_empty() {
        raise malformed("empty transfer coding")
      }
      codings.push(coding)
    }
  }
  if codings.filter(c => c == "chunked").length() > 1 {
    raise malformed("chunked applied more than once")
  }
  if codings is ["chunked"] {
    return Some(Chunked)
  }
  raise ParseError(kind=Unsupported, detail="unsupported transfer coding")
}

///|
/// `Content-Length = 1*DIGIT`, refusing values past `Int64`.
fn content_length(value : String) -> Int64 raise ParseError {
  let value = ows(value)
  if value.is_empty() {
    raise malformed("empty Content-Length")
  }
  let mut length = 0L
  for c in value {
    guard c is ('0'..<='9') else { raise malformed("invalid Content-Length") }
    let digit = (c.to_int() - '0'.to_int()).to_int64()
    if length > (9223372036854775807L - digit) / 10L {
      raise malformed("Content-Length overflow")
    }
    length = length * 10L + digit
  }
  length
}

///|
/// Resolves the framing of a request body: `Length` from one valid
/// Content-Length, `Chunked` from a Transfer-Encoding of exactly `chunked`,
/// and `NoBody` when neither field is present. Refuses Content-Length with
/// Transfer-Encoding as smuggling, any duplicate or invalid Content-Length as
/// malformed, and any other transfer coding as unsupported.
///
/// ```mbt check
/// test {
///   let chunked = @http.Headers::of([("Transfer-Encoding", "chunked")])
///   assert_eq(@h1.request_framing(chunked), Chunked)
///   let both = chunked.add("Content-Length", "5")
///   try @h1.request_framing(both) catch {
///     @h1.ParseError(kind~, ..) => assert_eq(kind, Smuggling)
///   } noraise {
///     _ => fail("CL+TE must be refused")
///   }
/// }
/// ```
pub fn request_framing(headers : @http.Headers) -> Framing raise ParseError {
  framing_fields(headers).unwrap_or(NoBody)
}

///|
/// Resolves the framing of a response body to `meth`. The fields are
/// checked as for `request_framing` even when the status has no body; then
/// a response to HEAD, a 1xx, 204 or 304, and a 2xx to CONNECT have
/// `NoBody`, and a response with neither field reads `UntilClose`. After a
/// successful CONNECT the caller hands the remaining bytes to the tunnel.
pub fn response_framing(
  headers : @http.Headers,
  status~ : Int32,
  meth~ : @http.Method = Get,
) -> Framing raise ParseError {
  let framing = framing_fields(headers)
  if has_no_body(status, meth) {
    return NoBody
  }
  framing.unwrap_or(UntilClose)
}

///|
/// Whether a response never has a body, whatever its fields say (RFC 9112,
/// section 6.3): a response to HEAD, a 1xx, 204 or 304, and a 2xx to
/// CONNECT.
fn has_no_body(status : Int32, meth : @http.Method) -> Bool {
  meth == Head ||
  status / 100 == 1 ||
  status == 204 ||
  status == 304 ||
  (meth == Connect && status / 100 == 2)
}

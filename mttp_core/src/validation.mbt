///|
/// Checks header names and values before serialization. Empty names and
/// non-token name characters are refused; values cannot contain controls
/// other than horizontal tab, or characters outside the HTTP byte range.
pub fn Headers::validate(self : Headers) -> Unit raise TransportError {
  for (name, value) in self.iter() {
    if name.is_empty() || !name.iter().all(is_token) {
      raise TransportError(
        kind=Invalid,
        phase=Pool,
        detail="invalid header name",
      )
    }
    for c in value {
      if (c < ' ' && c != '\t') || c == '\u007f' || c.to_int() > 255 {
        raise TransportError(
          kind=Invalid,
          phase=Pool,
          detail="invalid header value",
        )
      }
    }
  }
}

///|
fn is_token(c : Char) -> Bool {
  c is ('a'..<='z' | 'A'..<='Z' | '0'..<='9') ||
  "!#$%&'*+-.^_`|~".contains_char(c)
}

///|
/// Validates the original URL before normalization can encode an invalid
/// request target. Unicode text is permitted and encoded by the URL parser.
pub fn validate_url(url : String) -> Unit raise TransportError {
  for c in url {
    if c <= ' ' || c == '\u007f' {
      raise TransportError(
        kind=Invalid,
        phase=Pool,
        detail="URL contains a space or control character",
      )
    }
  }
}

///|
/// Validates the method token, raw URL, headers and declared stream length
/// before a backend sends it. A stream body declaring a negative length is
/// refused here as `StreamBody::take` would refuse it, and its source is
/// closed, since no sender will take it.
pub fn Request::validate(self : Request) -> Unit raise TransportError {
  let meth = self.meth.to_string()
  if meth.is_empty() || !meth.iter().all(is_token) {
    raise TransportError(kind=Invalid, phase=Pool, detail="invalid HTTP method")
  }
  validate_url(self.url)
  self.headers.validate()
  if self.body is Stream(stream) && stream.length is Some(length) && length < 0L {
    ignore(stream.take())
  }
}

///|
/// Reads and closes a stream, refusing the first chunk that crosses `limit`.
/// Subtraction before comparison prevents accumulated-length overflow.
pub async fn read_bounded(
  stream : &BodyStream,
  limit : Int32,
) -> Bytes raise TransportError {
  defer stream.close()
  if limit < 0 {
    raise TransportError(kind=Invalid, phase=Body, detail="negative body limit")
  }
  let buffer = Buffer()
  while stream.read_some() is Some(chunk) {
    if chunk.is_empty() {
      raise TransportError(kind=Protocol, phase=Body, detail="empty body chunk")
    }
    if chunk.length() > limit - buffer.length() {
      raise TransportError(
        kind=TooLarge(limit~),
        phase=Body,
        detail="body exceeds limit",
      )
    }
    buffer.write_bytes(chunk)
  }
  buffer.to_bytes()
}

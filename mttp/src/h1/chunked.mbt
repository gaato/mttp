///|
priv enum ChunkState {
  Size
  Data(Int64)
  DataCr
  DataLf
  Trailers
  Done
}

///|
/// What one `ChunkedDecoder::feed` produced. `chunks` are nonempty payload
/// pieces whose boundaries follow the input. `trailers` holds the trailer
/// fields received so far and is complete once `done`. `consumed` counts the
/// bytes of this feed that belong to the body; bytes after it belong to the
/// next message.
#derive(Eq, Debug)
pub struct Decoded {
  /// Payload pieces, in order; never empty.
  chunks : Array[Bytes]
  /// Whether the last chunk and the trailer section ended.
  done : Bool
  /// Trailer fields, names lowercased, duplicates retained.
  trailers : @mttp.Headers
  /// How many bytes of this feed belong to the body.
  consumed : Int32
}

///|
/// Compares decoder results.
pub extend Decoded with Eq::{equal, not_equal}

///|
/// Formats decoder results.
pub extend Decoded with @debug.Debug::{to_repr}

///|
/// An incremental decoder of the chunked transfer coding (RFC 9112, section
/// 7.1). It keeps only the current size or trailer line and the trailer
/// fields, never a chunk's payload, so its memory is bounded by `Limits`
/// whatever chunk sizes the peer declares. Errors are sticky.
pub struct ChunkedDecoder {
  priv limits : Limits
  priv line : Buffer
  priv mut line_cr : Bool
  priv mut state : ChunkState
  priv mut trailer_bytes : Int32
  priv trailers : Array[(String, String)]
  priv mut failure : ParseError?
}

///|
/// Creates a decoder bounded by `limits.max_chunk_line_bytes` per size line
/// and by `max_trailer_bytes` and `max_headers` for the trailer section. A
/// negative limit is refused by the first `feed`.
///
/// ```mbt check
/// test {
///   let decoder = @h1.ChunkedDecoder::new(@h1.Limits::default())
///   let result = decoder.feed(b"4\r\nWiki\r\n0\r\nX-Sum: 1\r\n\r\nnext")
///   assert_eq(result.chunks, [b"Wiki"])
///   assert_true(result.done)
///   assert_eq(result.trailers.get("x-sum"), Some("1"))
///   assert_eq(result.consumed, 24)
///   decoder.finish()
/// }
/// ```
pub fn ChunkedDecoder::new(limits : Limits) -> ChunkedDecoder {
  {
    limits,
    line: Buffer(),
    line_cr: false,
    state: Size,
    trailer_bytes: 0,
    trailers: [],
    failure: None,
  }
}

///|
fn ChunkedDecoder::fail(
  self : ChunkedDecoder,
  error : ParseError,
) -> ParseError {
  self.failure = Some(error)
  self.line.reset()
  error
}

///|
/// Skips BWS (`*( SP / HTAB )`) from `i`.
fn skip_bws(line : StringView, i : Int32) -> Int32 {
  let mut j = i
  while j < line.length() && line[j] is (' ' | '\t') {
    j += 1
  }
  j
}

///|
/// Skips a nonempty token from `i`, or raises.
fn skip_token(
  line : StringView,
  i : Int32,
  what : String,
) -> Int32 raise ParseError {
  let mut j = i
  while j < line.length() && line.get_char(j) is Some(c) && is_tchar(c) {
    j += 1
  }
  if j == i {
    raise malformed("empty \{what}")
  }
  j
}

///|
/// Skips a quoted string whose opening quote is at `i - 1`.
fn skip_quoted(line : StringView, i : Int32) -> Int32 raise ParseError {
  for j = i; j < line.length(); {
    match line.get_char(j) {
      Some('"') => return j + 1
      Some('\\') => {
        guard line.get_char(j + 1) is Some(escaped) && is_field_char(escaped) else {
          raise malformed("invalid quoted-pair in chunk extension")
        }
        continue j + 2
      }
      Some(c) if is_field_char(c) => continue j + 1
      _ => raise malformed("invalid character in chunk extension")
    }
  }
  raise malformed("unterminated quoted chunk extension")
}

///|
/// Parses `chunk-size [ chunk-ext ]` (RFC 9112, section 7.1.1):
/// `chunk-ext = *( BWS ";" BWS name [ BWS "=" BWS ( token / quoted ) ] )`.
/// Extensions are validated and ignored. Whitespace is allowed only around
/// extension delimiters, never before the size or after a size alone.
fn chunk_size(line : StringView) -> Int64 raise ParseError {
  let mut size = 0L
  let mut i = 0
  while i < line.length() {
    let digit = match line[i] {
      '0'..<='9' as c => c.to_int() - '0'.to_int()
      'a'..<='f' as c => c.to_int() - 'a'.to_int() + 10
      'A'..<='F' as c => c.to_int() - 'A'.to_int() + 10
      _ => break
    }
    if size > (9223372036854775807L - digit.to_int64()) / 16L {
      raise malformed("chunk size overflow")
    }
    size = size * 16L + digit.to_int64()
    i += 1
  }
  if i == 0 {
    raise malformed("invalid chunk size")
  }
  while i < line.length() {
    i = skip_bws(line, i)
    guard i < line.length() && line[i] == ';' else {
      raise malformed("invalid chunk size or extension")
    }
    i = skip_token(line, skip_bws(line, i + 1), "chunk extension name")
    let j = skip_bws(line, i)
    if j < line.length() && line[j] == '=' {
      let k = skip_bws(line, j + 1)
      i = if k < line.length() && line[k] == '"' {
        skip_quoted(line, k + 1)
      } else {
        skip_token(line, k, "chunk extension value")
      }
    }
  }
  size
}

///|
/// Trailer fields that would change framing or routing if a recipient
/// merged them into the head (RFC 9110, section 6.5.1).
let forbidden_trailers : Array[String] = [
  "content-length", "transfer-encoding", "host", "connection", "trailer",
]

///|
/// Consumes the bytes of `bytes` that belong to the body and returns the
/// payload they carried. Report the end of input with `finish`: a zero-size
/// chunk is not complete until the trailer section's final CRLF arrives.
/// A size line or trailer section past its limit raises `HeadTooLarge`; a
/// trailer that names a framing or routing field raises `Smuggling`.
pub fn ChunkedDecoder::feed(
  self : ChunkedDecoder,
  bytes : BytesView,
) -> Decoded raise ParseError {
  if self.failure is Some(error) {
    raise error
  }
  if self.limits.max_chunk_line_bytes < 0 ||
    self.limits.max_trailer_bytes < 0 ||
    self.limits.max_headers < 0 {
    raise self.fail(malformed("negative chunk limits"))
  }
  let chunks = []
  let mut i = 0
  while i < bytes.length() {
    match self.state {
      Done => break
      Data(remaining) => {
        let count = remaining.min((bytes.length() - i).to_int64()).to_int()
        chunks.push(bytes[i:i + count].to_owned())
        i += count
        self.state = if remaining == count.to_int64() {
          DataCr
        } else {
          Data(remaining - count.to_int64())
        }
      }
      DataCr => {
        if bytes[i] != b'\r' {
          raise self.fail(malformed("chunk data lacks CRLF"))
        }
        i += 1
        self.state = DataLf
      }
      DataLf => {
        if bytes[i] != b'\n' {
          raise self.fail(malformed("chunk data lacks CRLF"))
        }
        i += 1
        self.state = Size
      }
      Size | Trailers => {
        let byte = bytes[i]
        i += 1
        self.line_byte(byte) catch {
          ParseError(..) as error => raise self.fail(error)
        }
      }
    }
  }
  {
    chunks,
    done: self.state is Done,
    trailers: @mttp.Headers::of(self.trailers),
    consumed: i,
  }
}

///|
/// Adds one byte to the current size or trailer line and handles the line
/// once its CRLF arrived.
fn ChunkedDecoder::line_byte(
  self : ChunkedDecoder,
  byte : Byte,
) -> Unit raise ParseError {
  let is_trailer = self.state is Trailers
  if is_trailer {
    if self.trailer_bytes >= self.limits.max_trailer_bytes {
      raise too_large(
        "trailer section exceeds \{self.limits.max_trailer_bytes} bytes",
      )
    }
    self.trailer_bytes += 1
  } else if self.line.length() >= self.limits.max_chunk_line_bytes {
    raise too_large(
      "chunk size line exceeds \{self.limits.max_chunk_line_bytes} bytes",
    )
  }
  if (self.line_cr && byte != b'\n') || (byte == b'\n' && !self.line_cr) {
    raise malformed("chunk line requires CRLF")
  }
  self.line.write_byte(byte)
  self.line_cr = byte == b'\r'
  if byte != b'\n' {
    return
  }
  let data = self.line.to_bytes()
  self.line.reset()
  let line = latin1(data[:data.length() - 2])
  if !is_trailer {
    let size = chunk_size(line)
    self.state = if size == 0L { Trailers } else { Data(size) }
  } else if line.is_empty() {
    self.state = Done
  } else {
    if self.trailers.length() >= self.limits.max_headers {
      raise too_large("more than \{self.limits.max_headers} trailer fields")
    }
    let pair = field(line)
    if forbidden_trailers.contains(pair.0) {
      raise ParseError(kind=Smuggling, detail="framing field in trailers")
    }
    self.trailers.push(pair)
  }
}

///|
/// Checks at end of input that the body ended; a truncated body raises, and
/// the error is sticky.
pub fn ChunkedDecoder::finish(self : ChunkedDecoder) -> Unit raise ParseError {
  if self.failure is Some(error) {
    raise error
  }
  if !(self.state is Done) {
    raise self.fail(malformed("truncated chunked body"))
  }
}

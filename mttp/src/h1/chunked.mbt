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
/// Decoded body pieces and trailer fields. Consumed excludes any bytes from
/// a following message. Chunks are nonempty; their boundaries follow input.
pub struct Decoded {
  chunks : Array[Bytes]
  done : Bool
  trailers : @model.Headers
  consumed : Int32
}

///|
/// Incremental chunk framing decoder. Retains only bounded size/trailer
/// lines and trailer fields, never a whole chunk body. Failures are sticky.
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
/// Creates a decoder with explicit limits; negative limits fail on feed.
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
fn chunk_size(line : String) -> Int64 raise ParseError {
  let split = line.find(";").unwrap_or(line.length())
  let text = ows(line[:split].to_owned())
  if text.is_empty() {
    raise malformed("empty chunk size")
  }
  let mut size = 0L
  for c in text {
    let digit = match c {
      '0'..<='9' => c.to_int() - '0'.to_int()
      'a'..<='f' => c.to_int() - 'a'.to_int() + 10
      'A'..<='F' => c.to_int() - 'A'.to_int() + 10
      _ => raise malformed("invalid chunk size")
    }
    if size > (9223372036854775807L - digit.to_int64()) / 16L {
      raise malformed("chunk size overflow")
    }
    size = size * 16L + digit.to_int64()
  }
  // BWS is permitted around extension delimiters, not before the size.
  if line[0] == ' ' ||
    line[0] == '\t' ||
    (split == line.length() && text != line) {
    raise malformed("whitespace in chunk size")
  }
  let mut i = split
  while i < line.length() {
    if line[i] != ';' {
      raise malformed("invalid chunk extension")
    }
    i += 1
    while i < line.length() && (line[i] == ' ' || line[i] == '\t') {
      i += 1
    }
    let start = i
    while i < line.length() && token(line[i:i + 1].to_owned()) {
      i += 1
    }
    if i == start {
      raise malformed("empty chunk extension")
    }
    while i < line.length() && (line[i] == ' ' || line[i] == '\t') {
      i += 1
    }
    if i < line.length() && line[i] == '=' {
      i += 1
      while i < line.length() && (line[i] == ' ' || line[i] == '\t') {
        i += 1
      }
      if i < line.length() && line[i] == '"' {
        i += 1
        let mut closed = false
        while i < line.length() {
          let c = line[i]
          i += 1
          if c == '"' {
            closed = true
            break
          }
          if c == '\\' {
            if i >= line.length() {
              raise malformed("truncated quoted extension")
            }
            let escaped = line[i]
            if (escaped < 32 && escaped != 9) || escaped == 127 {
              raise malformed("invalid quoted extension")
            }
            i += 1
          } else if (c < 32 && c != 9) || c == 127 {
            raise malformed("invalid quoted extension")
          }
        }
        if !closed {
          raise malformed("unterminated chunk extension")
        }
      } else {
        let start = i
        while i < line.length() && token(line[i:i + 1].to_owned()) {
          i += 1
        }
        if start == i {
          raise malformed("empty extension value")
        }
      }
      while i < line.length() && (line[i] == ' ' || line[i] == '\t') {
        i += 1
      }
    }
  }
  size
}

///|
/// Consumes a prefix of input. EOF must be reported with finish; a zero-size
/// chunk is not complete until the trailer section's final CRLF arrives.
/// The synchronous catch stores the precise failure for later calls.
#warnings("-fragile_catch_all")
pub fn ChunkedDecoder::feed(
  self : ChunkedDecoder,
  bytes : BytesView,
) -> Decoded raise ParseError {
  if self.failure is Some(error) {
    raise error
  }
  try {
    if self.limits.max_chunk_line_bytes < 0 ||
      self.limits.max_trailer_bytes < 0 ||
      self.limits.max_headers < 0 {
      raise malformed("negative chunk limits")
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
            raise malformed("chunk data lacks CRLF")
          }
          i += 1
          self.state = DataLf
        }
        DataLf => {
          if bytes[i] != b'\n' {
            raise malformed("chunk data lacks LF")
          }
          i += 1
          self.state = Size
        }
        Size | Trailers => {
          let is_trailer = self.state is Trailers
          if is_trailer {
            if self.trailer_bytes >= self.limits.max_trailer_bytes {
              raise malformed("trailers exceed limit")
            }
            self.trailer_bytes += 1
          } else if self.line.length() >= self.limits.max_chunk_line_bytes {
            raise malformed("chunk size line exceeds limit")
          }
          let byte = bytes[i]
          i += 1
          if (self.line_cr && byte != b'\n') || (byte == b'\n' && !self.line_cr) {
            raise malformed("chunk line requires CRLF")
          }
          self.line.write_byte(byte)
          self.line_cr = byte == b'\r'
          if byte == b'\n' {
            let data = self.line.to_bytes()
            self.line.reset()
            let line = latin1(data[:data.length() - 2])
            if is_trailer {
              if line.is_empty() {
                self.state = Done
              } else {
                if self.trailers.length() >= self.limits.max_headers {
                  raise malformed("too many trailers")
                }
                let pair = field(line)
                if [
                    "content-length", "transfer-encoding", "host", "connection",
                    "trailer",
                  ].contains(pair.0) {
                  raise ParseError(
                    kind=Smuggling,
                    detail="forbidden framing trailer",
                  )
                }
                self.trailers.push(pair)
              }
            } else {
              let size = chunk_size(line)
              self.state = if size == 0L { Trailers } else { Data(size) }
            }
          }
        }
      }
    }
    {
      chunks,
      done: self.state is Done,
      trailers: @model.Headers::of(self.trailers),
      consumed: i,
    }
  } catch {
    error => {
      self.failure = Some(error)
      self.line.reset()
      raise error
    }
  }
}

///|
/// Verifies complete framing at EOF; incomplete bodies become sticky errors.
pub fn ChunkedDecoder::finish(self : ChunkedDecoder) -> Unit raise ParseError {
  if self.failure is Some(error) {
    raise error
  }
  if !(self.state is Done) {
    let error = malformed("truncated chunked body")
    self.failure = Some(error)
    self.line.reset()
    raise error
  }
}

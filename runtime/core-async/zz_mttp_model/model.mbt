// Sans-IO vocabulary shared verbatim by the 0.22.5 build and the core-main
// build. It must import nothing from any async runtime.

///|
#non_exhaustive
pub(all) enum Phase {
  Pool
  Dial
  Write
  Head
  Body
  Unknown
} derive(Eq, @debug.Debug)

///|
#non_exhaustive
pub(all) enum Kind {
  Invalid
  Connect
  Timeout(ms~ : Int)
  Network
  Protocol
  TooLarge(limit~ : Int64)
  Closed
} derive(Eq, @debug.Debug)

///|
pub(all) suberror TransportError {
  TransportError(kind~ : Kind, phase~ : Phase, detail~ : String)
} derive(@debug.Debug)

///|
pub struct Headers {
  priv pairs : Array[(String, String)]
}

///|
pub fn Headers::of(pairs : ArrayView[(String, String)]) -> Headers {
  let out = []
  for p in pairs {
    out.push(p)
  }
  { pairs: out }
}

///|
pub fn Headers::empty() -> Headers {
  { pairs: [] }
}

///|
pub fn Headers::get_all(self : Headers, name : String) -> Array[String] {
  let n = name.to_lower()
  self.pairs.filter(p => p.0.to_lower() == n).map(p => p.1)
}

///|
pub fn Headers::get(self : Headers, name : String) -> String? {
  self.get_all(name).get(0)
}

///|
pub fn Headers::add(self : Headers, name : String, value : String) -> Headers {
  let pairs = self.pairs.copy()
  pairs.push((name, value))
  { pairs, }
}

///|
pub fn Headers::iter(self : Headers) -> Iter[(String, String)] {
  self.pairs.iter()
}

///|
pub fn Headers::length(self : Headers) -> Int {
  self.pairs.length()
}

///|
pub(open) trait BodyStream {
  async fn read_some(Self) -> Bytes? raise TransportError
  fn close(Self) -> Unit
}

///|
pub(all) enum Body {
  Empty
  Bytes(Bytes)
  Stream(&BodyStream, length~ : Int64?)
}

///|
pub(all) struct Request {
  meth : String
  url : String
  headers : Headers
  body : Body
}

///|
pub(all) struct Response {
  status : Int
  headers : Headers
  body : Body
}

///|
pub(all) enum ServerBody {
  Empty
  Bytes(Bytes)
  Stream(&BodyStream, length~ : Int64?)
  Push(async (async (Bytes) -> Unit raise TransportError) -> Unit, length~ : Int64?)
}

///|
pub(all) struct ServerResponse {
  status : Int
  headers : Headers
  body : ServerBody
  close_connection : Bool
}

///|
pub(all) enum Outcome {
  Respond(ServerResponse)
}

///|
pub type Handler = async (Request) -> Outcome noraise

///|
/// Reads a stream to its end, refusing at the chunk that crosses `limit`.
pub async fn read_bounded(
  s : &BodyStream,
  limit : Int,
) -> Bytes raise TransportError {
  let buf = @buffer.Buffer()
  while s.read_some() is Some(chunk) {
    if chunk.length() > limit - buf.length() {
      s.close()
      raise TransportError(
        kind=TooLarge(limit=limit.to_int64()),
        phase=Body,
        detail="body over \{limit} bytes",
      )
    }
    buf.write_bytes(chunk)
  }
  buf.to_bytes()
}

///|
/// Sans-IO bounded HTTP/1.1 request-head scanner: given the bytes buffered so
/// far, returns the head length (including the blank line) once complete,
/// None when more bytes are needed, and raises when `max` is exceeded.
pub fn scan_head(data : BytesView, max~ : Int) -> Int? raise TransportError {
  let n = data.length()
  for i = 3; i < n; i = i + 1 {
    if data[i] == b'\n' && data[i - 1] == b'\r' && data[i - 2] == b'\n' &&
      data[i - 3] == b'\r' {
      if i + 1 > max {
        break
      }
      return Some(i + 1)
    }
  }
  if n >= max {
    raise TransportError(
      kind=TooLarge(limit=max.to_int64()),
      phase=Head,
      detail="request head over \{max} bytes",
    )
  }
  None
}

///|
/// Parses the header lines of a complete head, keeping duplicates in order.
pub fn parse_head_headers(head : BytesView) -> Headers {
  let text = @utf8.decode_lossy(head)
  let lines = text.split("\r\n").collect()
  let pairs = []
  for i = 1; i < lines.length(); i = i + 1 {
    let line = lines[i]
    if line.is_empty() {
      continue
    }
    if line.find(":") is Some(c) {
      pairs.push(
        (line[:c].to_owned(), line[c + 1:].trim(chars=" \t").to_owned()),
      )
    }
  }
  { pairs, }
}

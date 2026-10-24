///|
pub(all) enum Method {
  Get
  Head
  Post
  Put
  Patch
  Delete
  Options
  Trace
  Connect
  Other(String)
} derive(Eq, Hash, Debug)

///|
pub fn Method::as_str(self : Method) -> String {
  match self {
    Get => "GET"
    Head => "HEAD"
    Post => "POST"
    Put => "PUT"
    Patch => "PATCH"
    Delete => "DELETE"
    Options => "OPTIONS"
    Trace => "TRACE"
    Connect => "CONNECT"
    Other(s) => s
  }
}

///|
pub(all) struct Status(Int) derive(Eq, Hash, Debug)

///|
pub fn Status::code(self : Status) -> Int {
  self.0
}

///|
pub fn Status::is_success(self : Status) -> Bool {
  self.0 >= 200 && self.0 < 300
}

///|
/// Case-insensitive, order-preserving, multi-valued. Names stored lower-case.
pub struct Headers {
  priv entries : Array[(String, String)]
} derive(Eq, Debug)

///|
pub fn Headers::new() -> Headers {
  { entries: [] }
}

///|
pub fn Headers::from_array(pairs : Array[(String, String)]) -> Headers {
  { entries: pairs.map(p => (p.0.to_lower(), p.1)) }
}

///|
pub fn Headers::get(self : Headers, name : String) -> String? {
  let name = name.to_lower()
  for e in self.entries {
    if e.0 == name {
      return Some(e.1)
    }
  }
  None
}

///|
pub fn Headers::get_all(self : Headers, name : String) -> Array[String] {
  let name = name.to_lower()
  self.entries.filter(e => e.0 == name).map(e => e.1)
}

///|
/// Persistent: returns a new value.
pub fn Headers::add(self : Headers, name : String, value : String) -> Headers {
  { entries: [..self.entries, (name.to_lower(), value)] }
}

///|
pub fn Headers::iter(self : Headers) -> Iter[(String, String)] {
  self.entries.iter()
}

///|
/// Decoded path segments and query pairs; encoding happens in `to_string`.
pub(all) struct Uri {
  scheme : String?
  authority : String?
  segments : Array[String]
  query : Array[(String, String)]
} derive(Eq, Debug)

///|
pub fn Uri::relative(segments : Array[String]) -> Uri {
  { scheme: None, authority: None, segments, query: [] }
}

///|
pub fn Uri::with_segments(self : Uri, more : Array[String]) -> Uri {
  { ..self, segments: [..self.segments, ..more] }
}

///|
pub fn Uri::add_query(self : Uri, k : String, v : String) -> Uri {
  { ..self, query: [..self.query, (k, v)] }
}

///|
pub fn Uri::query_all(self : Uri, k : String) -> Array[String] {
  self.query.filter(p => p.0 == k).map(p => p.1)
}

///|
pub fn percent_encode(s : String, keep_slash~ : Bool = false) -> String {
  let b = StringBuilder::new()
  for byte in @utf8.encode(s) {
    let c = byte.to_int()
    let unreserved = (c >= 'a'.to_int() && c <= 'z'.to_int()) ||
      (c >= 'A'.to_int() && c <= 'Z'.to_int()) ||
      (c >= '0'.to_int() && c <= '9'.to_int()) ||
      c == '-'.to_int() ||
      c == '.'.to_int() ||
      c == '_'.to_int() ||
      c == '~'.to_int() ||
      (keep_slash && c == '/'.to_int())
    if unreserved {
      b.write_char(Int::unsafe_to_char(c))
    } else {
      let hex = "0123456789ABCDEF"
      b.write_char('%')
      b.write_char(hex[c >> 4].unsafe_to_char())
      b.write_char(hex[c & 15].unsafe_to_char())
    }
  }
  b.to_string()
}

///|
pub fn Uri::to_string(self : Uri) -> String {
  let b = StringBuilder::new()
  if self.scheme is Some(s) {
    b.write_string(s)
    b.write_string("://")
  }
  if self.authority is Some(a) {
    b.write_string(a)
  }
  for s in self.segments {
    b.write_char('/')
    b.write_string(percent_encode(s))
  }
  if self.segments.is_empty() {
    b.write_char('/')
  }
  for i, p in self.query {
    b.write_char(if i == 0 { '?' } else { '&' })
    b.write_string(percent_encode(p.0))
    b.write_char('=')
    b.write_string(percent_encode(p.1))
  }
  b.to_string()
}

///|
/// `b <+ "https://api.example.com/users/\{id}"`: literal parts verbatim,
/// interpolated parts percent-encoded as one segment or query value.
pub struct UriBuilder {
  priv buf : StringBuilder
}

///|
pub fn UriBuilder::new() -> UriBuilder {
  { buf: StringBuilder::new() }
}

///|
pub fn UriBuilder::write_string(self : UriBuilder, s : String) -> Unit {
  self.buf.write_string(s)
}

///|
pub fn[T : Show] UriBuilder::write_string_interpolation(
  self : UriBuilder,
  value : T,
) -> Unit {
  self.buf.write_string(percent_encode(value.to_string()))
}

///|
pub fn UriBuilder::raw(self : UriBuilder) -> String {
  self.buf.to_string()
}

///|
/// Pull-based body: the reader decides when to ask for more. Same rules as
/// gaato CONTRACT.md 9-12. Maps 1:1 onto core/async/io BinaryReader::read.
pub(open) trait BodyStream {
  async read_some(Self) -> Bytes? raise TransportError
  close(Self) -> Unit
}

///|
pub(all) enum Body {
  Empty
  Bytes(Bytes)
  Stream(&BodyStream, length~ : Int64?)
}

///|
pub fn Body::is_replayable(self : Body) -> Bool {
  self is (Empty | Bytes(_))
}

///|
pub(all) struct Request {
  meth : Method
  uri : Uri
  headers : Headers
  body : Body
}

///|
pub fn Request::new(meth : Method, uri : Uri) -> Request {
  { meth, uri, headers: Headers::new(), body: Empty }
}

///|
pub(all) struct ResponseHead {
  status : Status
  headers : Headers
} derive(Eq, Debug)

///|
pub(all) struct Response {
  status : Status
  headers : Headers
  body : Body
}

///|
pub fn Response::head(self : Response) -> ResponseHead {
  { status: self.status, headers: self.headers }
}

///|
/// Where a transport failure happened.
#non_exhaustive
pub(all) enum Phase {
  Pool
  Dial
  Write
  Head
  Body
  Unknown
} derive(Eq, Debug)

///|
/// The exchange produced no usable response. Statuses are never errors here.
pub(all) suberror TransportError {
  Connect(String)
  Timeout(phase~ : Phase, ms~ : Int)
  Network(phase~ : Phase, message~ : String)
  Protocol(String)
  LimitExceeded(what~ : String, limit~ : Int64)
} derive(Debug)

///|
pub fn TransportError::is_unsent(self : TransportError) -> Bool {
  match self {
    Connect(_) | Timeout(phase=Pool | Dial, ..) => true
    _ => false
  }
}

///|
/// An in-memory stream; used by tests and the in-process stub.
pub struct BytesStream {
  priv chunks : Array[Bytes]
  priv mut next : Int
  priv mut closed : Bool
  priv mut reads : Int
}

///|
pub fn BytesStream::new(chunks : Array[Bytes]) -> BytesStream {
  { chunks, next: 0, closed: false, reads: 0 }
}

///|
pub fn BytesStream::reads(self : BytesStream) -> Int {
  self.reads
}

///|
pub fn BytesStream::closed(self : BytesStream) -> Bool {
  self.closed
}

///|
pub impl BodyStream for BytesStream with read_some(self) {
  self.reads += 1
  if self.closed || self.next >= self.chunks.length() {
    return None
  }
  let c = self.chunks[self.next]
  self.next += 1
  Some(c)
}

///|
pub impl BodyStream for BytesStream with close(self) {
  self.closed = true
}

///|
/// Read a stream to its end, refusing past `limit` (refuse, never truncate).
pub async fn read_bounded(
  s : &BodyStream,
  limit : Int64,
) -> Bytes raise TransportError {
  let buf = @buffer.new()
  let mut total = 0L
  while s.read_some() is Some(chunk) {
    total += chunk.length().to_int64()
    if total > limit {
      s.close()
      raise LimitExceeded(what="body", limit~)
    }
    buf.write_bytes(chunk)
  }
  s.close()
  buf.to_bytes()
}

///|
/// WebSocket frames as the endpoint layer sees them; ping/pong is the
/// adapter's business.
pub(all) enum Frame {
  Text(String)
  Binary(Bytes)
  Close(code~ : Int, reason~ : String)
} derive(Eq, Debug)

///|
pub(open) trait WebSocketIo {
  async recv(Self) -> Frame? raise TransportError
  async send(Self, Frame) -> Unit raise TransportError
  close(Self) -> Unit
}

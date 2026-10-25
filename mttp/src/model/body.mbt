// Request bodies. A stream body is read once, so whatever may send a request
// twice (a replay on a stale connection, a retry, a 307 or 308 redirect)
// asks `Body::is_replayable` first, as the Fetch Standard does with a body
// whose source is null; `StreamBody::take` refuses a second reader, so a
// sender that does not ask fails instead of sending a partial body.

///|
/// A request body: bytes in memory, or a stream read as the request is sent.
///
/// ```mbt check
/// test {
///   let request = @model.Request::post("/upload").body_bytes(b"abc")
///   assert_eq(request.body, Bytes(b"abc"))
///   assert_eq(request.body.length(), Some(3L))
///   assert_true(request.body.is_replayable())
/// }
/// ```
#non_exhaustive
pub(all) enum Body {
  /// An empty, replayable body.
  Empty
  /// Bytes in memory, which can be sent any number of times.
  Bytes(Bytes)
  /// A stream, read once by the transport that sends it.
  Stream(StreamBody)
} derive(Eq, Debug)

///|
/// Equality: equal bytes, or the same `StreamBody`.
pub extend Body with Eq::{equal, not_equal}

///|
/// Debug representation of a body; a stream shows its length, not its bytes.
pub extend Body with @debug.Debug::{to_repr}

///|
/// The number of bytes the body will send, when it is known: the length of
/// the bytes, or the length a stream was declared with.
pub fn Body::length(self : Body) -> Int64? {
  match self {
    Empty => Some(0L)
    Bytes(bytes) => Some(bytes.length().to_int64())
    Stream(stream) => stream.length
  }
}

///|
/// The bytes of a body held in memory, or `None` for a stream (as reqwest's
/// `Body::as_bytes`).
pub fn Body::as_bytes(self : Body) -> Bytes? {
  match self {
    Empty => Some(b"")
    Bytes(bytes) => Some(bytes)
    Stream(_) => None
  }
}

///|
/// Whether a sender may send this body (again): always for bytes, and for a
/// stream only while no transport has taken it.
pub fn Body::is_replayable(self : Body) -> Bool {
  match self {
    Empty => true
    Bytes(_) => true
    Stream(stream) => !stream.taken
  }
}

///|
/// A request body read once from a `BodyStream`, with its length when known.
///
/// A transport sends a known length as `Content-Length` and an unknown one,
/// on HTTP/1.1, as `Transfer-Encoding: chunked`. The transport that sends the
/// body takes it (`take`) and closes the stream when it is done with it, sent
/// or failed; a stream that is never taken stays open and is its creator's to
/// close. Two stream bodies are equal only when they are the same one.
pub struct StreamBody {
  priv source : &BodyStream
  priv length : Int64?
  priv mut taken : Bool
}

///|
/// Wraps `source`, declared to produce exactly `length` bytes when given.
pub fn StreamBody::new(source : &BodyStream, length? : Int64) -> StreamBody {
  { source, length, taken: false, }
}

///|
/// The declared length, if any.
pub fn StreamBody::length(self : StreamBody) -> Int64? {
  self.length
}

///|
/// Closes the source and prevents future acquisition.
pub fn StreamBody::close(self : StreamBody) -> Unit {
  self.taken = true
  self.source.close()
}

///|
/// Hands the stream to the one sender that reads it. The returned stream
/// raises `Protocol` when the source produces more bytes than the declared
/// length, or ends before it; its `close` closes the source.
///
/// A second call raises `Protocol`, since the bytes already read are gone. A
/// negative declared length raises `Protocol` before anything is read, and
/// closes the source, which no sender will take.
pub fn StreamBody::take(self : StreamBody) -> &BodyStream raise TransportError {
  if self.taken {
    raise TransportError(kind=Unreplayable, phase=Write, detail=already_taken)
  }
  if self.length is Some(length) && length < 0L {
    // Refused for good: the source is closed here, as no sender will.
    self.taken = true
    self.source.close()
    raise TransportError(
      kind=Invalid,
      phase=Write,
      detail="a stream request body cannot declare a negative length",
    )
  }
  self.taken = true
  TakenStream::{
    source: self.source,
    length: self.length,
    read: 0L,
    closed: false,
  }
}

///|
let already_taken : String = "the stream request body was already sent; a stream can be sent only once"

///|
/// Identity: the same stream body, not an equal one.
pub extend StreamBody with Eq::{equal, not_equal}

///|
/// Debug representation of a stream body.
pub extend StreamBody with @debug.Debug::{to_repr}

///|
/// Identity: the same stream body, not an equal one.
pub impl Eq for StreamBody with fn equal(self, other) {
  physical_equal(self, other)
}

///|
/// Shows the declared length and whether the stream was taken.
pub impl @debug.Debug for StreamBody with fn to_repr(self) {
  @debug.Repr::ctor("StreamBody", [
    (Some("length"), @debug.Repr(self.length)),
    (Some("taken"), @debug.Repr::bool(self.taken)),
  ])
}

///|
/// A taken stream body, counting what it has read against the declared length.
priv struct TakenStream {
  source : &BodyStream
  length : Int64?
  mut read : Int64
  mut closed : Bool
}

///|
impl BodyStream for TakenStream with fn read_some(self) {
  if self.closed {
    return None
  }
  errdefer BodyStream::close(self)
  let chunk = self.source.read_some()
  if chunk is Some(bytes) && bytes.is_empty() {
    BodyStream::close(self)
    raise TransportError(kind=Protocol, phase=Body, detail="empty body chunk")
  }
  if length_violation(self.length, self.read, chunk.map(Bytes::length))
    is Some(message) {
    BodyStream::close(self)
    raise TransportError(kind=Protocol, phase=Body, detail=message)
  }
  if chunk is Some(bytes) {
    self.read += bytes.length().to_int64()
  } else {
    BodyStream::close(self)
  }
  chunk
}

///|
impl BodyStream for TakenStream with fn close(self) {
  if !self.closed {
    self.closed = true
    self.source.close()
  }
}

///|
/// Why a stream declared as `length` bytes is wrong after `read` bytes and
/// then a chunk of `chunk` bytes, or its end (`None`); `None` when it is not.
fn length_violation(length : Int64?, read : Int64, chunk : Int32?) -> String? {
  guard length is Some(declared) else { return None }
  match chunk {
    Some(size) if size.to_int64() > declared - read =>
      Some("request body stream is longer than its declared \{declared} bytes")
    None if read < declared =>
      Some(
        "request body stream ended after \{read} of its declared \{declared} bytes",
      )
    _ => None
  }
}

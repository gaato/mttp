///|
/// CONTRACT rules 9-11: None = end and stays end; chunks never empty; close idempotent.
pub(open) trait BodyStream {
  async fn read_some(Self) -> Bytes? raise TransportError
  fn close(Self) -> Unit
}

///|
#non_exhaustive
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
/// Refuses at the chunk that crosses the limit.
pub async fn read_bounded(
  s : &BodyStream,
  limit : Int,
) -> Bytes raise TransportError {
  // Closed however the read ends: completion, the limit, or a read error.
  defer s.close()
  let buf = Buffer()
  while s.read_some() is Some(chunk) {
    if buf.length() + chunk.length() > limit {
      raise TransportError(
        kind=TooLarge(limit~),
        phase=Body,
        detail="body over \{limit} bytes",
      )
    }
    buf.write_bytes(chunk)
  }
  buf.to_bytes()
}

///|
/// Not in the architecture's model sketch; every test double and the
/// in-process stub need one, so it is listed here as a finding.
pub struct BytesStream {
  priv chunks : Array[Bytes]
  priv mut next : Int
  priv mut closed : Bool
  priv mut reads : Int
}

///|
pub fn BytesStream::new(chunks : Array[Bytes]) -> BytesStream {
  { chunks: chunks.filter(c => c.length() > 0), next: 0, closed: false, reads: 0 }
}

///|
pub fn BytesStream::reads(self : BytesStream) -> Int {
  self.reads
}

///|
pub fn BytesStream::is_closed(self : BytesStream) -> Bool {
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

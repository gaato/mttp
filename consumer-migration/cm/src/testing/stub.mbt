///|
pub struct FakeClock {
  priv mut now : Int64
  slept : Array[Int]
}

///|
pub fn FakeClock::new() -> FakeClock {
  { now: 1_700_000_000_000L, slept: [] }
}

///|
pub impl @model.Clock for FakeClock with sleep(self, ms) {
  self.slept.push(ms)
  self.now += ms.to_int64()
}

///|
pub impl @model.Clock for FakeClock with now_unix_ms(self) {
  self.now
}

///|
priv struct ChunkStream {
  chunks : Array[Bytes]
  mut index : Int
  closed : Ref[Int]
}

///|
impl @model.BodyStream for ChunkStream with read_some(self) {
  if self.index >= self.chunks.length() {
    return None
  }
  self.index += 1
  Some(self.chunks[self.index - 1])
}

///|
impl @model.BodyStream for ChunkStream with close(self) {
  self.closed.val += 1
}

///|
/// Strict FIFO stub: each send pops the next canned (status, headers, chunks).
pub struct Stub {
  queue : Array[(Int, Array[(String, String)], Array[String])]
  sent : Array[@model.Request]
  closed : Ref[Int]
}

///|
pub fn Stub::new(queue : Array[(Int, Array[(String, String)], Array[String])]) -> Stub {
  { queue, sent: [], closed: Ref(0) }
}

///|
pub fn Stub::backend(self : Stub) -> &@client.Backend {
  @client.from_fn((req, _opts) => {
    self.sent.push(req)
    guard self.queue.length() > 0 else {
      raise TransportError(kind=Protocol, phase=Head, detail="stub exhausted")
    }
    let (status, headers, chunks) = self.queue.remove(0)
    let stream : &@model.BodyStream = ChunkStream::{
      chunks: chunks.map(c => @utf8.encode(c)),
      index: 0,
      closed: self.closed,
    }
    { status, headers: @model.Headers(headers), body: Stream(stream, length=None) }
  })
}

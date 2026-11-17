///|
priv struct Chunks {
  mut index : Int32
}

///|
impl @mttp.BodyStream for Chunks with fn read_some(self) {
  let chunk = match self.index {
    0 => Some(b"one\n")
    1 => Some(b"two\n")
    _ => None
  }
  if self.index < 2 {
    self.index += 1
  }
  chunk
}

///|
impl @mttp.BodyStream for Chunks with fn close(self) {
  self.index = 2
}

///|
pub fn response_stream_after(_ : @mttp.Request) -> @mttp.Response {
  @mttp.Response::new(
    200,
    body=Stream(@mttp.StreamBody::new(Chunks::{ index: 0, })),
  )
}

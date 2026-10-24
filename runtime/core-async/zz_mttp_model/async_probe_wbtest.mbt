///|
async test "async test in a package that does not import core/async" {
  let s : &BodyStream = OneShot::{ data: Some(b"abc") }
  inspect(read_bounded(s, 10), content="b\"abc\"")
}

///|
priv struct OneShot {
  mut data : Bytes?
}

///|
impl BodyStream for OneShot with read_some(self) {
  let d = self.data
  self.data = None
  d
}

///|
impl BodyStream for OneShot with close(_) {
  ()
}

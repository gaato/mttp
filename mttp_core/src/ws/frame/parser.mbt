///|
/// Incremental frame decoder. Feed retains views, never copies an entire
/// frame. Drain next until None before feeding again to bound queued input
/// by the caller's read size. Head storage is always fourteen bytes.
pub struct Parser {
  role : Role
  max_frame_bytes : Int32
  allow_rsv1 : Bool
  mut input : @queue.Queue[BytesView]
  mut current : BytesView
  header : FixedArray[Byte]
  mut have : Int32
  mut remaining : Int32
  mut mask : Bytes?
  mut offset : Int32
  mut stage : Int32
  mut failure : FrameError?
}

///|
/// A negative limit is refused by next, even before receiving any bytes.
pub fn Parser::new(
  role~ : Role,
  max_frame_bytes~ : Int32,
  allow_rsv1~ : Bool,
) -> Parser {
  {
    role,
    max_frame_bytes,
    allow_rsv1,
    input: @queue.Queue([]),
    current: b"",
    header: FixedArray::make(14, b'\x00'),
    have: 0,
    remaining: 0,
    mask: None,
    offset: 0,
    stage: 0,
    failure: None,
  }
}

///|
/// Queues a view; empty input and input after permanent failure are ignored.
pub fn Parser::feed(self : Parser, bytes : BytesView) -> Unit {
  if self.failure is None && !bytes.is_empty() {
    self.input.push(bytes)
  }
}

///|
fn Parser::available(self : Parser) -> Bool {
  if self.current.is_empty() {
    self.current = self.input.pop().unwrap_or(b"")
    // Queue's backing slots retain popped views. Drop the drained queue so
    // a parser waiting for its next read does not retain previous reads.
    if self.input.is_empty() {
      self.input = @queue.Queue([])
    }
  }
  !self.current.is_empty()
}

///|
fn Parser::fill(self : Parser, needed : Int32) -> Bool {
  while self.have < needed {
    if !self.available() {
      return false
    }
    let take = (needed - self.have).min(self.current.length())
    for i in 0..<take {
      self.header[self.have + i] = self.current[i]
    }
    self.have += take
    self.current = self.current[take:]
  }
  true
}

///|
fn Parser::step(self : Parser) -> Event? raise FrameError {
  if self.max_frame_bytes < 0 {
    raise protocol("negative max_frame_bytes")
  }
  if self.stage == 2 {
    self.stage = 0
    self.have = 0
    return Some(End)
  }
  if self.stage == 1 {
    if !self.available() {
      return None
    }
    let take = self.remaining.min(self.current.length())
    let piece = self.current[:take]
    let payload = match self.mask {
      Some(key) => apply_mask(piece, key, offset=self.offset)
      None => piece.to_owned()
    }
    self.current = self.current[take:]
    self.remaining -= take
    self.offset = (self.offset + take % 4) % 4
    if self.remaining == 0 {
      self.stage = 2
    }
    return Some(Payload(payload))
  }
  if !self.fill(2) {
    return None
  }
  let first = self.header[0].to_int()
  let second = self.header[1].to_int()
  let opcode = opcode_of(first & 15)
  let fin = (first & 0x80) != 0
  let rsv1 = (first & 0x40) != 0
  let masked = (second & 0x80) != 0
  if (first & 0x30) != 0 || (rsv1 && !self.allow_rsv1) {
    raise protocol("unnegotiated reserved bits")
  }
  if masked != (self.role is Server) {
    raise protocol("wrong mask direction")
  }
  let marker = second & 127
  if opcode.wire() >= 8 && (!fin || marker > 125 || rsv1) {
    raise protocol("invalid control frame")
  }
  let extended = if marker == 126 { 2 } else if marker == 127 { 8 } else { 0 }
  if !self.fill(2 + extended) {
    return None
  }
  if extended == 8 && (self.header[2].to_int() & 0x80) != 0 {
    raise protocol("64-bit length has its top bit set")
  }
  let mut length = if extended == 0 { marker.to_int64() } else { 0L }
  for i in 0..<extended {
    length = (length << 8) | self.header[2 + i].to_int64()
  }
  if (extended == 2 && length < 126L) || (extended == 8 && length < 65536L) {
    raise protocol("non-minimal length encoding")
  }
  let head = FrameHead::{ fin, rsv1, opcode, masked, length, }
  validate(head)
  if length > self.max_frame_bytes.to_int64() {
    raise FrameError(
      kind=TooLarge(limit=self.max_frame_bytes),
      detail="frame payload exceeds limit",
    )
  }
  let end = 2 + extended
  if masked {
    if !self.fill(end + 4) {
      return None
    }
    self.mask = Some(Bytes::makei(4, i => self.header[end + i]))
  } else {
    self.mask = None
  }
  self.remaining = length.to_int()
  self.offset = 0
  self.stage = if length == 0L { 2 } else { 1 }
  Some(Head(head))
}

///|
/// None means more input is needed. End marks a frame, not transport EOF;
/// the session detects truncated frames on transport EOF. Failures stay and
/// release queued input; subsequent feed cannot recover the parser.
pub fn Parser::next(self : Parser) -> Event? raise FrameError {
  if self.failure is Some(error) {
    raise error
  }
  self.step() catch {
    FrameError(..) as error => {
      self.failure = Some(error)
      self.current = b""
      self.input = @queue.Queue([])
      raise error
    }
  }
}

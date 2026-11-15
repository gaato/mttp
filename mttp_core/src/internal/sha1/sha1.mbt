///|
/// RFC 3174 SHA-1 for Sec-WebSocket-Accept only. SHA-1 is broken for
/// cryptographic security; do not use this package for authentication or signing.
pub struct Sha1 {
  words : FixedArray[UInt32]
  block : FixedArray[Byte]
  mut used : Int32
  mut length : UInt64
}

///|
/// Creates a fresh digest with fixed-size state, independent of input length.
pub fn Sha1::new() -> Sha1 {
  {
    words: [0x67452301U, 0xefcdab89U, 0x98badcfeU, 0x10325476U, 0xc3d2e1f0U],
    block: FixedArray::make(64, b'\x00'),
    used: 0,
    length: 0UL,
  }
}

///|
fn rotl(word : UInt32, bits : Int32) -> UInt32 {
  (word << bits) | (word >> (32 - bits))
}

///|
fn Sha1::compress(self : Sha1) -> Unit {
  let w : FixedArray[UInt32] = FixedArray::make(80, 0U)
  for i in 0..<16 {
    let at = i * 4
    w[i] = (self.block[at].to_uint() << 24) |
      (self.block[at + 1].to_uint() << 16) |
      (self.block[at + 2].to_uint() << 8) |
      self.block[at + 3].to_uint()
  }
  for i in 16..<80 {
    w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
  }
  let mut a = self.words[0]
  let mut b = self.words[1]
  let mut c = self.words[2]
  let mut d = self.words[3]
  let mut e = self.words[4]
  for i in 0..<80 {
    let (f, k) = if i < 20 {
      ((b & c) | ((b ^ 0xffffffffU) & d), 0x5a827999U)
    } else if i < 40 {
      (b ^ c ^ d, 0x6ed9eba1U)
    } else if i < 60 {
      ((b & c) | (b & d) | (c & d), 0x8f1bbcdcU)
    } else {
      (b ^ c ^ d, 0xca62c1d6U)
    }
    let next = rotl(a, 5) + f + e + k + w[i]
    e = d
    d = c
    c = rotl(b, 30)
    b = a
    a = next
  }
  self.words[0] += a
  self.words[1] += b
  self.words[2] += c
  self.words[3] += d
  self.words[4] += e
}

///|
/// Adds bytes without retaining the input; at most 63 bytes await a block.
pub fn Sha1::update(self : Sha1, bytes : BytesView) -> Unit {
  self.length += bytes.length().to_uint64()
  for byte in bytes {
    self.block[self.used] = byte
    self.used += 1
    if self.used == 64 {
      self.compress()
      self.used = 0
    }
  }
}

///|
/// Returns the 20-byte digest of the bytes so far without changing the state.
/// Repeated finishes and further updates are allowed.
pub fn Sha1::finish(self : Sha1) -> Bytes {
  let copy : Sha1 = {
    words: self.words.copy(),
    block: self.block.copy(),
    used: self.used,
    length: self.length,
  }
  let bits = self.length * 8UL
  copy.update(b"\x80")
  while copy.used != 56 {
    copy.update(b"\x00")
  }
  let end = Bytes::makei(8, i => (bits >> ((7 - i) * 8)).to_byte())
  copy.update(end)
  Bytes::makei(20, i => (copy.words[i / 4] >> ((3 - i % 4) * 8)).to_byte())
}

///|
/// One-shot SHA-1 for the WebSocket handshake, not for security.
pub fn digest(bytes : BytesView) -> Bytes {
  let state = Sha1::new()
  state.update(bytes)
  state.finish()
}

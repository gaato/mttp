///|
/// Encodes a minimal-length head. A masked head needs exactly four mask
/// bytes; an unmasked one needs None. RSV1 on data frames is the negotiated
/// extension's responsibility; control frames cannot use extensions.
pub fn encode_head(head : FrameHead, mask? : Bytes) -> Bytes raise FrameError {
  validate(head)
  if head.masked != (mask is Some(_)) ||
    (mask is Some(key) && key.length() != 4) {
    raise protocol("head mask flag and four-byte key must agree")
  }
  let out = Buffer(capacity=14)
  let first = (if head.fin { 0x80 } else { 0 }) |
    (if head.rsv1 { 0x40 } else { 0 }) |
    head.opcode.wire()
  out.write_byte(first.to_byte())
  let flag = if head.masked { 0x80 } else { 0 }
  if head.length < 126L {
    out.write_byte((flag | head.length.to_int()).to_byte())
  } else {
    let width = if head.length < 65536L { 2 } else { 8 }
    out.write_byte((flag | (if width == 2 { 126 } else { 127 })).to_byte())
    for i in 0..<width {
      out.write_byte((head.length >> ((width - 1 - i) * 8)).to_byte())
    }
  }
  if mask is Some(key) {
    out.write_bytes(key)
  }
  out.to_bytes()
}

///|
/// Masks or unmasks one piece. Offset counts preceding payload bytes (or
/// their value modulo four), so splitting a payload does not restart the key.
pub fn apply_mask(
  bytes : BytesView,
  mask : Bytes,
  offset~ : Int32 = 0,
) -> Bytes raise FrameError {
  if mask.length() != 4 || offset < 0 {
    raise protocol("mask needs four bytes and a nonnegative offset")
  }
  Bytes::makei(bytes.length(), i => bytes[i] ^ mask[(offset % 4 + i % 4) % 4])
}

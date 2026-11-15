///|
/// Strict RFC 3629 validation across pieces and frame boundaries. No input
/// is retained. Invalidity is sticky; finish also refuses incomplete input.
pub struct Utf8Validator {
  mut remaining : Int32
  mut low : Int32
  mut high : Int32
  mut valid : Bool
}

///|
/// Starts an independent text message's validator.
pub fn Utf8Validator::new() -> Utf8Validator {
  { remaining: 0, low: 0x80, high: 0xbf, valid: true, }
}

///|
/// Returns false at the first byte that proves invalidity, including a
/// restricted second byte of E0, ED, F0 or F4. True may still be incomplete.
pub fn Utf8Validator::push(self : Utf8Validator, bytes : BytesView) -> Bool {
  if !self.valid {
    return false
  }
  for byte in bytes {
    let b = byte.to_int()
    if self.remaining > 0 {
      if b < self.low || b > self.high {
        self.valid = false
        return false
      }
      self.remaining -= 1
      self.low = 0x80
      self.high = 0xbf
    } else if b <= 0x7f {
      continue
    } else if b >= 0xc2 && b <= 0xdf {
      self.remaining = 1
    } else if b >= 0xe0 && b <= 0xef {
      self.remaining = 2
      self.low = if b == 0xe0 { 0xa0 } else { 0x80 }
      self.high = if b == 0xed { 0x9f } else { 0xbf }
    } else if b >= 0xf0 && b <= 0xf4 {
      self.remaining = 3
      self.low = if b == 0xf0 { 0x90 } else { 0x80 }
      self.high = if b == 0xf4 { 0x8f } else { 0xbf }
    } else {
      self.valid = false
      return false
    }
  }
  true
}

///|
/// Checks completeness so far without ending validation; false for an
/// incomplete prefix can become true after push supplies its continuation.
pub fn Utf8Validator::finish(self : Utf8Validator) -> Bool {
  self.valid && self.remaining == 0
}

///|
/// A sample in [0, 1) for retry jitter and multipart boundaries: host
/// randomness when the target has it, otherwise a deterministic xorshift
/// sequence. Neither is suitable for secrets, tokens or cryptographic nonces.
/// Code that must be reproducible takes a random source as a parameter with
/// this function as its default.
pub fn default_random() -> Double {
  random_sample(@env.rand(6), random_state)
}

///|
let random_state : Ref[UInt64] = Ref(0x9E3779B97F4A7C15UL)

///|
/// Maps six host bytes to [0, 1), or advances the fallback state.
fn random_sample(bytes : Bytes?, state : Ref[UInt64]) -> Double {
  match bytes {
    Some(bytes) => {
      let mut value = 0L
      for byte in bytes {
        value = value * 256L + byte.to_int().to_int64()
      }
      value.to_double() / 281474976710656.0
    }
    None => {
      let mut value = state.val
      value = value ^ (value << 13)
      value = value ^ (value >> 7)
      value = value ^ (value << 17)
      state.val = value
      (value >> 11).to_double() / 9007199254740992.0
    }
  }
}

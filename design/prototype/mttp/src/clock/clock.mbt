///|
/// Architecture §3.1, moved from gaato/http/clock + sync + random.
pub(open) trait Clock {
  async fn sleep(Self, Int) -> Unit noraise
  fn now_unix_ms(Self) -> Int64
}

///|
pub(open) trait Timer {
  async fn within(Self, Int, async () -> Unit noraise) -> Bool noraise
}

///|
pub(open) trait Gate {
  async fn acquire(Self) -> Unit noraise
  fn release(Self) -> Unit
}

///|
let random_state : Ref[UInt64] = { val: 0x9E3779B97F4A7C15UL }

///|
pub fn default_random() -> Double {
  match @env.rand(6) {
    Some(bytes) => {
      let mut value = 0L
      for byte in bytes {
        value = value * 256L + byte.to_int().to_int64()
      }
      value.to_double() / 281474976710656.0
    }
    None => {
      let mut value = random_state.val
      value = value ^ (value << 13)
      value = value ^ (value >> 7)
      value = value ^ (value << 17)
      random_state.val = value
      (value >> 11).to_double() / 9007199254740992.0
    }
  }
}

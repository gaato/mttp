///|
pub struct FakeClock {
  priv mut now : Int64
  priv delays : Array[Int]
}

///|
/// Architecture §3.1 writes `start_unix_ms? : Int64`; gaato/http today has
/// `start_unix_ms~ : Int64 = 0L`. Kept as today.
pub fn FakeClock::new(start_unix_ms~ : Int64 = 0L) -> FakeClock {
  { now: start_unix_ms, delays: [] }
}

///|
pub fn FakeClock::advance(self : FakeClock, ms : Int) -> Unit {
  self.now += ms.to_int64()
}

///|
pub fn FakeClock::slept(self : FakeClock) -> Array[Int] {
  self.delays.copy()
}

///|
pub impl @clock.Clock for FakeClock with sleep(self, ms) {
  self.delays.push(ms)
  if ms > 0 {
    self.now += ms.to_int64()
  }
}

///|
pub impl @clock.Clock for FakeClock with now_unix_ms(self) {
  self.now
}

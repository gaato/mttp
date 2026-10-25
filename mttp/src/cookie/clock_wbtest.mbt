///|
priv struct FixedClock(Int64)

///|
impl @clock.Clock for FixedClock with fn now_unix_ms(self) {
  self.0
}

///|
impl @clock.Clock for FixedClock with fn sleep(_, _) {
  ()
}

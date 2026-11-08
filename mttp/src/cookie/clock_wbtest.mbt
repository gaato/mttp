///|
priv struct FixedClock(Int64)

///|
impl @rt.Clock for FixedClock with fn now_unix_ms(self) {
  self.0
}

///|
impl @rt.Clock for FixedClock with fn sleep(_, _) {
  ()
}

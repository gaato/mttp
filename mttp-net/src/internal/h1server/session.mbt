///|
pub(all) struct Connection {
  wire : Wire
  mut control : @control.SessionState
  activity : (Bool) -> Unit
}

///|
pub fn Connection::new(
  wire : Wire,
  activity~ : (Bool) -> Unit = _ => (),
) -> Connection {
  { wire, control: @control.SessionState::new(), activity, }
}

///|
pub fn Connection::set_busy(self : Connection, busy : Bool) -> Unit {
  self.control = self.control.step(if busy { Begin } else { Finish }).state
  (self.activity)(busy)
}

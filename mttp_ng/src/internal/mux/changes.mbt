// The one way the engines of this module wait: for a condition on state
// that other tasks change, until an absolute deadline.
//
// Two faults came from waiting by hand (`timer.within(ms, () => wait())` on
// a shared condition): a change between the check and the wait was lost,
// since `within` suspends before its body waits (h2spec found a handler that
// waited out its body timeout), and a wake-up by any other change started a
// fresh timeout, so unrelated traffic kept a stalled body read alive
// (Codex's review of #58). Here a waiter takes the current signal before it
// suspends, and the signal is sticky, so no change is lost; and the deadline
// is a point in time, so a wake-up that does not satisfy the condition
// leaves less time, not more.

///|
/// Changes of some shared state, for tasks that wait on it.
pub struct Changes {
  priv coordination : &@rt.Coordination
  priv clock : &@rt.Clock
  priv timer : &@rt.Timer
  priv mut signal : &@rt.Signal
}

///|
/// Changes rung through `coordination`'s signals, with deadlines on `clock`
/// and `timer`.
pub fn Changes::new(
  coordination : &@rt.Coordination,
  clock : &@rt.Clock,
  timer : &@rt.Timer,
) -> Changes {
  { coordination, clock, timer, signal: coordination.signal(), }
}

///|
/// Wakes every task waiting now. Tasks that start waiting later see the
/// state as it is then.
pub fn Changes::notify(self : Changes) -> Unit {
  let woken = self.signal
  self.signal = self.coordination.signal()
  woken.notify()
}

///|
/// The signal the next `notify` rings, for a caller that waits on it beside
/// something else (`Coordination::supervise`). Taken before the condition
/// is looked at, it cannot miss a change made after the look.
pub fn Changes::next(self : Changes) -> &@rt.Signal {
  self.signal
}

///|
/// The point `ms` milliseconds from now, for `wait_until`.
pub fn Changes::deadline_in(self : Changes, ms : Int32) -> Int64 {
  self.clock.now_unix_ms() + ms.to_int64()
}

///|
/// Waits until `done` holds: `true`, or `false` when `deadline` (a
/// `now_unix_ms` value; `None` for none) passed first. `done` is looked at
/// before every wait and after every change.
pub async fn Changes::wait_until(
  self : Changes,
  done : () -> Bool,
  deadline? : Int64,
) -> Bool noraise {
  while !done() {
    let signal = self.signal
    match deadline {
      None => signal.wait()
      Some(at) => {
        let left = at - self.clock.now_unix_ms()
        if left <= 0L {
          return done()
        }
        let ms = if left > 0x7fffffffL { 0x7fffffff } else { left.to_int() }
        ignore(self.timer.within(ms, () => signal.wait()))
      }
    }
  }
  true
}

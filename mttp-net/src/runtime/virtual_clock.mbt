///|
/// The requested test observation was not reached within the scheduling budget.
pub(all) suberror NoQuiescence {
  NoQuiescence(rounds~ : Int32)
}

///|
priv struct VirtualWaiter {
  deadline : Int64
  requested : Int32
  mut fired : Bool
  cond : @cond_var.Cond
}

///|
/// A manually advanced clock for runtime tests. Advancing time wakes the
/// currently registered due sleepers; it does not claim the runtime is idle.
/// Use `settle(until=...)` to wait for an explicit observation before the next
/// advance. Periodic work is driven one deadline at a time with
/// `advance_to_next`, observing its result before advancing again.
pub struct VirtualClock {
  priv mut now : Int64
  priv waiters : Array[VirtualWaiter]
}

///|
/// Creates a virtual clock with no pending timers.
pub fn VirtualClock::VirtualClock(
  start_ms~ : Int64 = 1_700_000_000_000L,
) -> VirtualClock {
  { now: start_ms, waiters: [], }
}

///|
/// Explicit clock methods for injection into HTTP and application policies.
pub extend VirtualClock with @clock.Clock::{sleep, now_unix_ms}

///|
/// Returns the manually controlled timestamp.
pub impl @clock.Clock for VirtualClock with fn now_unix_ms(self) {
  self.now
}

///|
/// Parks until an explicit advance reaches the deadline; cancellation removes
/// the waiter. A nonpositive duration yields once without adding a timer.
pub impl @clock.Clock for VirtualClock with fn sleep(self, milliseconds) {
  if milliseconds <= 0 {
    @async.pause()
    return
  }
  let duration = milliseconds.to_int64()
  // Saturate instead of wrapping a test clock near the end of Int64 time.
  let deadline = if self.now > 9223372036854775807L - duration {
    9223372036854775807L
  } else {
    self.now + duration
  }
  let waiter = VirtualWaiter::{
    deadline,
    requested: milliseconds,
    fired: false,
    cond: @cond_var.Cond(),
  }
  self.waiters.push(waiter)
  defer self.waiters.retain(other => !physical_equal(other, waiter))
  while !waiter.fired {
    waiter.cond.wait()
  }
}

///|
/// Waits until the caller's observation holds, yielding between checks.
/// No progress counter or fixed quiet period is interpreted as global idleness.
/// Cancellation propagates; exhausting the budget raises `NoQuiescence`.
pub async fn VirtualClock::settle(
  self : VirtualClock,
  until~ : () -> Bool,
  max_rounds~ : Int32 = 100_000,
) -> Unit raise NoQuiescence {
  ignore(self)
  if until() {
    return
  }
  for _ in 0..<max_rounds.max(0) {
    @async.pause()
    if until() {
      return
    }
  }
  raise NoQuiescence(rounds=max_rounds.max(0))
}

///|
/// Requested durations of pending sleeps, in deadline then registration order.
pub fn VirtualClock::pending(self : VirtualClock) -> Array[Int32] {
  let sorted = self.waiters.mapi((index, waiter) => (index, waiter))
  sorted.sort_by((a, b) => {
    match a.1.deadline.compare(b.1.deadline) {
      0 => a.0.compare(b.0)
      order => order
    }
  })
  sorted.map(pair => pair.1.requested)
}

///|
/// Earliest registered deadline, without running or advancing any task.
pub fn VirtualClock::next_deadline(self : VirtualClock) -> Int64? {
  let mut result : Int64? = None
  for waiter in self.waiters {
    result = Some(
      match result {
        Some(value) => value.min(waiter.deadline)
        None => waiter.deadline
      },
    )
  }
  result
}

///|
/// Advances by a nonnegative duration and wakes all currently due timers in
/// registration order. Negative durations leave time unchanged. Newly scheduled
/// sleeps start at this new timestamp, not at an inferred intermediate instant.
pub fn VirtualClock::advance(self : VirtualClock, milliseconds : Int32) -> Unit {
  let delta = milliseconds.max(0).to_int64()
  self.now = if self.now > 9223372036854775807L - delta {
    9223372036854775807L
  } else {
    self.now + delta
  }
  let due = self.waiters.filter(waiter => waiter.deadline <= self.now)
  self.waiters.retain(waiter => waiter.deadline > self.now)
  for waiter in due {
    waiter.fired = true
    waiter.cond.signal()
  }
}

///|
/// Moves to the earliest deadline and wakes all timers at that instant.
/// Returns false when no timer is registered. Observe their work with `settle`
/// before asking for another deadline.
pub fn VirtualClock::advance_to_next(self : VirtualClock) -> Bool {
  guard self.next_deadline() is Some(deadline) else { return false }
  self.now = self.now.max(deadline)
  self.advance(0)
  true
}

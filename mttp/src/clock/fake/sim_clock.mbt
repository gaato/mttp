///|
/// A clock sharing the driver's virtual time. Concurrent sleeps overlap.
pub struct SimClock {
  priv driver : @driver.Driver
}

///|
/// Creates a clock bound to the supplied scheduler.
pub fn SimClock::new(driver : @driver.Driver) -> SimClock {
  { driver, }
}

///|
/// Suspends the calling task until its virtual deadline.
pub impl @clock.Clock for SimClock with fn sleep(self, ms) {
  self.driver.sleep(ms)
}

///|
/// Returns the scheduler's timestamp in milliseconds.
pub impl @clock.Clock for SimClock with fn now_unix_ms(self) {
  self.driver.now()
}

///|
/// Exposes the clock operations on the concrete fake.
pub extend SimClock with @clock.Clock::{sleep, now_unix_ms}

///|
/// A deadline runner sharing the driver's virtual time and cancellation.
pub struct SimTimer {
  priv driver : @driver.Driver
}

///|
/// Creates a timer bound to the supplied scheduler.
pub fn SimTimer::new(driver : @driver.Driver) -> SimTimer {
  { driver, }
}

///|
/// Runs work until completion or its deadline. Nonpositive deadlines never
/// start the callback. A timeout cancels the child and waits for its unwind.
pub impl @clock.Timer for SimTimer with fn within(self, ms, f) {
  if ms <= 0 {
    return false
  }
  let mut completed = false
  let child = self.driver.spawn(
    () => {
      f()
      completed = true
    },
    label="SimTimer.within",
  )
  let timer = self.driver.add_timer(self.driver.now() + ms.to_int64(), () => {
    if !completed {
      child.cancel()
    }
  })
  defer {
    timer.cancel()
    if !child.is_finished() {
      self.driver.cancel_and_join([child])
    }
  }
  let _ = child.wait() catch { _ => false }
  completed
}

///|
/// Exposes the deadline operation on the concrete fake.
pub extend SimTimer with @clock.Timer::{within}

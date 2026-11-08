///|
/// A clock whose sleeps move its time forward at once: a sequential
/// accumulator, so overlapping sleeps add up. It records every requested
/// duration. Code that sleeps concurrently uses `SimClock` instead.
pub struct FakeClock {
  priv mut now : Int64
  priv delays : Array[Int32]
}

///|
/// Creates a fake clock at the Unix millisecond timestamp `start_unix_ms`.
///
/// ```mbt check
/// test {
///   let clock = @sim.FakeClock::new(start_unix_ms=123L)
///   @driver.run_sync(() => clock.sleep(5))
///   assert_eq(clock.now_unix_ms(), 128L)
///   assert_eq(clock.slept(), [5])
/// }
/// ```
pub fn FakeClock::new(start_unix_ms~ : Int64 = 0L) -> FakeClock {
  { now: start_unix_ms, delays: [], }
}

///|
/// A copy of every requested sleep duration, in order, nonpositive ones
/// included.
pub fn FakeClock::slept(self : FakeClock) -> Array[Int32] {
  self.delays.copy()
}

///|
/// Moves the wall time by `ms`, backward when negative, without recording a
/// sleep.
pub fn FakeClock::advance(self : FakeClock, ms : Int32) -> Unit {
  self.now += ms.to_int64()
}

///|
/// Records the sleep; only a positive duration moves the time.
pub impl @rt.Clock for FakeClock with fn sleep(self, ms) {
  self.delays.push(ms)
  if ms > 0 {
    self.now += ms.to_int64()
  }
}

///|
/// The fake Unix millisecond timestamp.
pub impl @rt.Clock for FakeClock with fn now_unix_ms(self) {
  self.now
}

///|
/// The clock operations as methods of the fake.
pub extend FakeClock with @rt.Clock::{sleep, now_unix_ms}

///|
/// A clock on a Driver's virtual time: concurrent sleeps overlap, so two
/// tasks sleeping 20 and 30 ms end 30 ms later.
pub struct SimClock {
  priv driver : @driver.Driver
}

///|
/// Creates a clock on `driver`'s time.
pub fn SimClock::new(driver : @driver.Driver) -> SimClock {
  { driver, }
}

///|
/// Suspends the calling task until its virtual deadline.
pub impl @rt.Clock for SimClock with fn sleep(self, ms) {
  self.driver.sleep(ms)
}

///|
/// The Driver's virtual time in milliseconds.
pub impl @rt.Clock for SimClock with fn now_unix_ms(self) {
  self.driver.now()
}

///|
/// The clock operations as methods of the double.
pub extend SimClock with @rt.Clock::{sleep, now_unix_ms}

///|
/// A Timer on a Driver's virtual time and cancellation.
pub struct SimTimer {
  priv driver : @driver.Driver
}

///|
/// Creates a timer on `driver`.
pub fn SimTimer::new(driver : @driver.Driver) -> SimTimer {
  { driver, }
}

///|
/// Runs `f` as a child task with a virtual deadline. A nonpositive deadline
/// never starts it; expiry cancels it and waits for it to unwind.
pub impl @rt.Timer for SimTimer with fn within(self, ms, f) {
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
/// The deadline operation as a method of the double.
pub extend SimTimer with @rt.Timer::{within}

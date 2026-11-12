///|
/// A `@rt.Timer` that bounds work on a clock, so sans-IO code such as
/// `gaato/mttp_core/client` can put a deadline on an attempt without importing
/// an async runtime.
pub struct ClockTimer {
  priv clock : &@rt.Clock
}

///|
/// Creates a timer on `clock`, the wall clock by default. Pass the clock the
/// transport times its phases on, or a controlled clock in tests.
///
/// ```mbt check
/// async test {
///   let timer = @runtime.ClockTimer::new()
///   let done = Ref(false)
///   assert_true(timer.within(1000, () => done.val = true))
///   assert_true(done.val)
/// }
/// ```
pub fn ClockTimer::new(clock? : &@rt.Clock) -> ClockTimer {
  { clock: clock.unwrap_or_else(() => AsyncClock::new()), }
}

///|
/// Explicit timer methods backed by the clock.
pub extend ClockTimer with @rt.Timer::{within}

///|
/// Runs `f` until it finishes or `milliseconds` pass on the clock, whichever
/// comes first; `false` means time ran out and `f` was cancelled. A
/// nonpositive budget returns `false` without starting `f`. Runtime
/// cancellation of the caller still propagates as a signal.
pub impl @rt.Timer for ClockTimer with fn within(self, milliseconds, f) {
  if milliseconds <= 0 {
    return false
  }
  let finished = with_timeout_opt(self.clock, milliseconds, () => f()) catch {
    _ => None
  }
  finished is Some(_)
}

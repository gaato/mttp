// The time and admission ports. The engines and the mttp client take them as
// trait objects, so they never import a runtime: gaato/mttp_async implements
// them on moonbitlang/core/async, and gaato/http/sim on the deterministic
// driver. CONTRACT.md (Clock, Timer, Gate) states what each side may rely on.

///|
/// A source of wall-clock time and of delays.
pub(open) trait Clock {
  /// Sleeps for `ms` milliseconds; a nonpositive value returns at once.
  /// Cancellation arrives as the scheduler's signal, never as an error.
  async fn sleep(Self, Int32) -> Unit noraise
  /// Milliseconds since the Unix epoch.
  fn now_unix_ms(Self) -> Int64
}

///|
/// A time limit for a piece of work. Trait methods cannot be generic, so the
/// work returns nothing: a caller that wants a result writes it into a cell
/// the closure captures.
pub(open) trait Timer {
  /// Runs `f` for at most `ms` milliseconds and returns whether it finished.
  /// On expiry `f` is cancelled and `within` returns false after `f` has
  /// unwound. A nonpositive `ms` returns false without starting `f`.
  /// Cancelling the caller cancels `f` and disarms the deadline.
  async fn within(Self, Int32, async () -> Unit noraise) -> Bool noraise
}

///|
/// A counting admission gate: a caller holds a slot across an exchange.
pub(open) trait Gate {
  /// Waits for a slot. Waiters are served in FIFO order; a waiter cancelled
  /// before the handoff leaves the queue without consuming a slot.
  async fn acquire(Self) -> Unit noraise
  /// Returns one slot taken by a successful `acquire`; extra releases are
  /// capped at the gate's capacity.
  fn release(Self) -> Unit
}

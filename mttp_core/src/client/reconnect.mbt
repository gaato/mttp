///|
/// When to reconnect a long-lived stream (an event stream, a WebSocket)
/// after it ended or failed, as data. `decide` applies it; the caller keeps
/// the count of reconnects and does the waiting, so the same policy serves
/// `Client::sse_reconnecting` and an application's own WebSocket loop.
///
/// ```mbt check
/// test {
///   let policy = {
///     ..@client.ReconnectPolicy::default(),
///     backoff: { base_ms: 500, max_ms: 8000, jitter: NoJitter, },
///     max_attempts: Some(3),
///   }
///   assert_eq(policy.decide(attempts=0, lived_ms=0L, random=0.5), Wait(500))
///   assert_eq(policy.decide(attempts=2, lived_ms=0L, random=0.5), Wait(2000))
///   assert_eq(policy.decide(attempts=3, lived_ms=0L, random=0.5), GiveUp)
///   // A connection that lived reset_after_ms starts the count again.
///   assert_eq(policy.decide(attempts=3, lived_ms=60000L, random=0.5), Wait(500))
///   assert_eq(policy.next_attempts(attempts=3, lived_ms=60000L), 1)
/// }
/// ```
#derive(Eq, Debug)
pub(all) struct ReconnectPolicy {
  /// The wait before reconnect number `attempts + 1`, from its base up to
  /// its cap.
  backoff : Backoff
  /// Reconnects allowed in a row before giving up; `None` never gives up.
  max_attempts : Int32?
  /// A connection that lived at least this long resets the count, so a
  /// stream that drops once a day reconnects quickly every time; 0 or less
  /// never resets it.
  reset_after_ms : Int32
  /// Whether a wait the server asked for (an event stream's `retry:` field,
  /// a `Retry-After` header) is used, within the backoff's cap.
  honour_server_retry : Bool
}

///|
/// Equality for reconnect policies.
pub extend ReconnectPolicy with Eq::{equal, not_equal}

///|
/// Debug representation of a reconnect policy.
pub extend ReconnectPolicy with @debug.Debug::{to_repr}

///|
/// What to do after a stream ended.
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum ReconnectDecision {
  /// Wait this many milliseconds, then reconnect.
  Wait(Int32)
  /// Do not reconnect.
  GiveUp
}

///|
/// Equality for reconnect decisions.
pub extend ReconnectDecision with Eq::{equal, not_equal}

///|
/// Debug representation of a reconnect decision.
pub extend ReconnectDecision with @debug.Debug::{to_repr}

///|
/// Reconnect for ever, waiting from 1 s doubling up to 30 s, each wait
/// spread over its upper half (`Proportional(lo=500, hi=1000)`) so clients
/// dropped together do not return together; a connection that lived 60 s
/// resets the count, and the server's `retry:` is honoured.
///
/// ```mbt check
/// test {
///   let policy = @client.ReconnectPolicy::default()
///   assert_eq(policy.max_attempts, None)
///   assert_eq(policy.decide(attempts=0, lived_ms=0L, random=0.0), Wait(500))
///   assert_eq(policy.decide(attempts=9, lived_ms=0L, random=0.0), Wait(15000))
/// }
/// ```
pub fn ReconnectPolicy::default() -> ReconnectPolicy {
  {
    backoff: {
      base_ms: 1000,
      max_ms: 30_000,
      jitter: Proportional(lo=500, hi=1000),
    },
    max_attempts: None,
    reset_after_ms: 60_000,
    honour_server_retry: true,
  }
}

///|
/// The reconnects that count against the policy: `attempts`, or 0 when the
/// connection that just ended lived at least `reset_after_ms`.
fn ReconnectPolicy::counted(
  self : ReconnectPolicy,
  attempts : Int32,
  lived_ms : Int64,
) -> Int32 {
  if self.reset_after_ms > 0 && lived_ms >= self.reset_after_ms.to_int64() {
    0
  } else {
    attempts.max(0)
  }
}

///|
/// The `attempts` to pass to the next `decide`, once the reconnect it
/// decided is made: one more than the reconnects that counted.
pub fn ReconnectPolicy::next_attempts(
  self : ReconnectPolicy,
  attempts~ : Int32,
  lived_ms~ : Int64,
) -> Int32 {
  self.counted(attempts, lived_ms) + 1
}

///|
/// Decides whether to reconnect after a connection ended, and how long to
/// wait.
///
/// - `attempts` counts the reconnects already made in a row (0 when the
///   stream first ends); `lived_ms` is how long the connection that just
///   ended was established (0 when it never was). A `lived_ms` of at least
///   `reset_after_ms` counts as 0 attempts.
/// - With `max_attempts` of `Some(n)`, `n` counted attempts give up.
/// - The wait is `backoff.delay_ms(attempts, random)`. With
///   `honour_server_retry` and a `server_hint_ms`, the hint (at least 0, at
///   most the backoff's `max_ms`) is the wait for the first reconnect and
///   the least wait for later ones, so repeated failures still back off.
///
/// The wait is never negative and never above `max(backoff.max_ms, 0)`.
pub fn ReconnectPolicy::decide(
  self : ReconnectPolicy,
  attempts~ : Int32,
  lived_ms~ : Int64,
  server_hint_ms? : Int32,
  random~ : Double,
) -> ReconnectDecision {
  let attempts = self.counted(attempts, lived_ms)
  if self.max_attempts is Some(max) && attempts >= max {
    return GiveUp
  }
  let backoff = self.backoff.delay_ms(attempts, random)
  match server_hint_ms {
    Some(hint) if self.honour_server_retry => {
      let hint = hint.max(0).min(self.backoff.max_ms.max(0))
      if attempts == 0 {
        Wait(hint)
      } else {
        Wait(hint.max(backoff))
      }
    }
    _ => Wait(backoff)
  }
}

///|
/// Remaining requests and the Unix millisecond instant when a window resets.
/// The field set is frozen.
#derive(Eq, Debug)
pub(all) struct RateLimitState {
  remaining : Int32
  reset_at_unix_ms : Int64
}

///|
/// Equality for rate-limit states.
pub extend RateLimitState with Eq::{equal, not_equal}

///|
/// Debug representation of rate-limit states.
pub extend RateLimitState with @debug.Debug::{to_repr}

///|
/// An account-wide admission window counted across buckets: at most `limit`
/// admissions in each `window_ms`. Both must be positive; a window with a
/// non-positive limit or length imposes no limit, since it would otherwise
/// block forever or reset on every admission. The field set is frozen.
#derive(Eq, Debug)
pub(all) struct GlobalWindow {
  limit : Int32
  window_ms : Int32
}

///|
/// Equality for global windows.
pub extend GlobalWindow with Eq::{equal, not_equal}

///|
/// Debug representation of global windows.
pub extend GlobalWindow with @debug.Debug::{to_repr}

///|
/// How far apart one group's admissions must be. `WindowLimiter::new(pace?)`
/// maps each bucket to its group; admissions in a group start at least
/// `min_interval_ms` apart, whatever the server's window says. A non-positive
/// interval imposes no spacing. The field set is frozen.
#derive(Eq, Debug)
pub(all) struct Pace {
  group : String
  min_interval_ms : Int32
}

///|
/// Equality for paces.
pub extend Pace with Eq::{equal, not_equal}

///|
/// Debug representation of paces.
pub extend Pace with @debug.Debug::{to_repr}

///|
/// What a 429 response does to a `WindowLimiter`. Each case applies the
/// Retry-After delay (or the configured default) differently.
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum LimitScope {
  /// The request's bucket is empty until the delay ends; the account-wide
  /// block is unchanged. The default.
  Bucket
  /// Every non-exempt request waits until the delay ends (extending, never
  /// shortening, the account-wide block); the bucket keeps its parsed state.
  Global
  /// A limit shared with other clients ran out: the bucket keeps only the
  /// state parsed from the headers, as for any other response, and is not
  /// emptied.
  Shared
  /// The response changes nothing: no state is recorded and no block is set.
  Ignore
}

///|
/// Equality for limit scopes.
pub extend LimitScope with Eq::{equal, not_equal}

///|
/// Debug representation of limit scopes.
pub extend LimitScope with @debug.Debug::{to_repr}

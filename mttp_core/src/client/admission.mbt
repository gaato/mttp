///|
/// Admission control for logical request buckets. Every completed acquire
/// has one release with that acquire's Admission, including cancellation and
/// decoding failures. Implementations ignore repeated releases of a token.
pub(open) trait RateLimiter {
  async fn acquire(Self, String, global_exempt~ : Bool) -> Admission
  async fn release(
    Self,
    Admission,
    status~ : Int32,
    headers~ : @mttp_core.Headers,
  ) -> Unit
}

///|
/// An admission issued by a RateLimiter. Return it only to its issuing limiter.
/// Copies identify the same admission; a second release is ignored.
pub struct Admission {
  priv bucket : String
  priv sequence : Int64
}

///|
/// Creates a token for a custom limiter. The issuer assigns a strictly
/// increasing sequence and tracks outstanding tokens to ignore duplicate releases.
pub fn Admission::new(bucket : String, sequence~ : Int64) -> Admission {
  { bucket, sequence, }
}

///|
/// The logical request bucket passed to acquire.
pub fn Admission::bucket(self : Admission) -> String {
  self.bucket
}

///|
/// The issuer's admission sequence, independent of response delivery time.
pub fn Admission::sequence(self : Admission) -> Int64 {
  self.sequence
}

///|
/// Admission without throttling or retained state.
pub struct NoLimiter {
  priv mut sequence : Int64
}

///|
/// Creates an admission controller that admits immediately.
pub fn NoLimiter::new() -> NoLimiter {
  { sequence: 0L, }
}

///|
/// Calls admission and release through method syntax.
pub extend NoLimiter with RateLimiter::{acquire, release}

///|
/// Admits immediately.
pub impl RateLimiter for NoLimiter with fn acquire(self, bucket, global_exempt~) {
  let _ = global_exempt
  if self.sequence == 9223372036854775807L {
    raise @mttp_core.TransportError(
      kind=Invalid,
      phase=Pool,
      detail="admission sequence exhausted",
    )
  }
  self.sequence += 1L
  Admission::new(bucket, sequence=self.sequence)
}

///|
/// Releases without retaining telemetry.
pub impl RateLimiter for NoLimiter with fn release(_, _, status~, headers~) {
  let _ = (status, headers)
}

///|
/// A settled attempt, reported after releasing admission. Attempt zero is
/// the initial send; status zero means no response head arrived.
pub(all) struct Attempt {
  request : @mttp_core.RequestHead
  /// Explicit caller annotations for observations, separate from the pure head.
  attributes : @mttp_core.Attributes
  bucket : String
  attempt : Int32
  status : Int32
  headers : @mttp_core.Headers
  duration_ms : Int64
  error : Error?
  decision : @retry.Decision?
}

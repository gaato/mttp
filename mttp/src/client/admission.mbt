///|
/// Admission control for logical request buckets. Every completed acquire
/// has one release, including cancellation and decoding failures.
pub(open) trait RateLimiter {
  async fn acquire(Self, String, global_exempt~ : Bool) -> Unit
  async fn release(Self, String, status~ : Int32, headers~ : @model.Headers) -> Unit
}

///|
/// Admission without throttling or retained state.
pub struct NoLimiter {}

///|
/// Creates an admission controller that admits immediately.
pub fn NoLimiter::new() -> NoLimiter {
  NoLimiter::{ }
}

///|
/// Calls admission and release through method syntax.
pub extend NoLimiter with RateLimiter::{acquire, release}

///|
/// Admits immediately.
pub impl RateLimiter for NoLimiter with fn acquire(_, _, global_exempt~) {
  let _ = global_exempt
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
  request : @model.RequestHead
  /// Explicit caller annotations for observations, separate from the pure head.
  attributes : @model.Attributes
  bucket : String
  attempt : Int32
  status : Int32
  headers : @model.Headers
  duration_ms : Int64
  error : Error?
  decision : @retry.Decision?
}

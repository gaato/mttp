// Clock-free arithmetic shared by client and server admission policies.

///|
#derive(Eq, Debug)
pub enum FixedStep {
  Admit(start~ : Int64, count~ : Int32)
  Wait(Int32)
}

///|
pub extend FixedStep with Eq::{equal, not_equal}

///|
pub extend FixedStep with Debug::{to_repr}

///|
/// A fixed window opens at the first admission. Its end is exclusive.
pub fn fixed_step(
  now : Int64,
  limit~ : Int32,
  window_ms~ : Int32,
  start~ : Int64?,
  count~ : Int32,
) -> FixedStep {
  let (start, count) = match start {
    Some(start) if now < saturating_add_ms(start, window_ms) => (start, count)
    _ => (now, 0)
  }
  if count < limit {
    Admit(start~, count=count + 1)
  } else {
    Wait(delay_until(saturating_add_ms(start, window_ms), now))
  }
}

///|
/// Exact sliding window: at most `limit` admission timestamps per key.
/// Owned by the decision; callers must not mutate its array.
pub struct Sliding {
  priv admitted : Array[Int64]
}

///|
pub enum SlidingStep {
  Admit(Sliding, remaining~ : Int32, reset_ms~ : Int32)
  Wait(Sliding, Int32)
}

///|
/// Admits at most limit events in (now - window_ms, now], with positive
/// limit/window_ms. Rollback retains future admissions until time catches up.
pub fn sliding_step(
  now : Int64,
  limit~ : Int32,
  window_ms~ : Int32,
  state : Sliding?,
) -> SlidingStep {
  let admitted = match state {
    Some(state) =>
      state.admitted.filter(at => now < at || delay_until(now, at) < window_ms)
    None => []
  }
  if admitted.length() < limit {
    admitted.push(now)
    Admit(
      { admitted, },
      remaining=limit - admitted.length(),
      reset_ms=delay_until(
        saturating_add_ms(
          admitted.fold(init=9223372036854775807L, (a, b) => a.min(b)),
          window_ms,
        ),
        now,
      ).max(1),
    )
  } else {
    Wait(
      { admitted, },
      delay_until(
        saturating_add_ms(
          admitted.fold(init=9223372036854775807L, (a, b) => a.min(b)),
          window_ms,
        ),
        now,
      ).max(1),
    )
  }
}

///|
/// Saturates to the largest sleep a Clock can accept rather than wrapping.
pub fn delay_until(until : Int64, now : Int64) -> Int32 {
  if until <= now {
    return 0
  }
  let delta = if now < 0L && until > 9223372036854775807L + now {
    9223372036854775807L
  } else {
    until - now
  }
  if delta > 2147483647L {
    2147483647
  } else {
    delta.to_int()
  }
}

///|
pub fn saturating_add_ms(now : Int64, milliseconds : Int32) -> Int64 {
  saturating_add_i64(now, milliseconds.to_int64())
}

///|
/// Positive durations saturate at the largest instant, preserving the
/// client's existing arithmetic contract.
pub fn saturating_add_i64(left : Int64, right : Int64) -> Int64 {
  if right > 0L && left > 9223372036854775807L - right {
    9223372036854775807L
  } else {
    left + right
  }
}

///|
// Release has no admission token, so responses in one bucket cannot be
// matched to requests. Until its outstanding cohort drains, charge every
// admission since the oldest possible request, including completed requests.
// This may understate quota but cannot replenish it from a delayed response.
fn WindowLimiter::admission_debt(
  self : WindowLimiter,
  bucket : String,
  key : String,
  now : Int64,
) -> Int32 {
  let own = self.admissions.get(bucket)
  let mut pending = 0L
  for active_bucket, active in self.admissions {
    if active_bucket == bucket || self.resolve(active_bucket, now) == key {
      pending = saturating_add_i64(pending, active.pending)
    }
  }
  if own is Some(_) {
    pending -= 1L
  }
  pending.min(2147483647L).to_int().max(own.map(a => a.later).unwrap_or(0))
}

///|
fn WindowLimiter::finish_admission(
  self : WindowLimiter,
  bucket : String,
) -> Unit {
  if self.admissions.get(bucket) is Some(active) {
    active.pending -= 1L
    if active.pending == 0L {
      self.admissions.remove(bucket)
    }
  }
}

///|
// Compare the server's reset instant independently of Retry-After. A later
// window replaces quota; an older window cannot replace it. Within a window,
// both responses and local consumption can only lower remaining quota.
// Bucket blocks survive every replacement and can only be extended.
fn reconcile(
  current : RecordedState,
  candidate : RecordedState,
) -> RecordedState {
  let blocked_until = current.blocked_until.max(candidate.blocked_until)
  if candidate.window_reset > current.window_reset {
    { ..candidate, blocked_until, }
  } else if candidate.window_reset < current.window_reset {
    { ..current, blocked_until, }
  } else {
    {
      ..current,
      value: {
        remaining: current.value.remaining.min(candidate.value.remaining),
        reset_at_unix_ms: current.value.reset_at_unix_ms.max(
          candidate.value.reset_at_unix_ms,
        ),
      },
      until: current.until.max(candidate.until),
      blocked_until,
    }
  }
}

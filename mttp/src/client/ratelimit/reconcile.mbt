///|
// Release has no admission token, so responses in one bucket cannot be
// matched to requests. Until its outstanding cohort drains, charge every
// admission since the oldest possible request, including completed requests.
// This may understate quota but cannot replenish it from a delayed response.
fn WindowLimiter::admission_debt(
  self : WindowLimiter,
  bucket : String,
  key : String,
) -> Int32 {
  let own = self.admissions.get(bucket)
  let mut pending = 0L
  for active_bucket, active in self.admissions {
    if active_bucket == bucket || self.routed_key(active_bucket) == key {
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
// Within that window a Retry-After overrides the ordinary quota deadline,
// including ordinary deadlines recorded before or after the 429.
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
    let deadline = if current.retry_override && !candidate.retry_override {
      current
    } else if candidate.retry_override && !current.retry_override {
      candidate
    } else if candidate.until > current.until {
      candidate
    } else {
      current
    }
    {
      ..current,
      value: {
        remaining: current.value.remaining.min(candidate.value.remaining),
        reset_at_unix_ms: deadline.value.reset_at_unix_ms,
      },
      until: deadline.until,
      blocked_until,
      retry_override: current.retry_override || candidate.retry_override,
    }
  }
}

///|
// Unswept, fully expired state is no longer a constraint. In particular, a
// stale Retry-After override must not expire live quota arriving at this key.
fn WindowLimiter::record(
  self : WindowLimiter,
  key : String,
  candidate : RecordedState,
  now : Int64,
) -> Unit {
  self.states[key] = match self.states.get(key) {
    Some(current) if current.until > now || current.blocked_until > now =>
      reconcile(current, candidate)
    _ => candidate
  }
}

///|
// Alias expiry is also a key transition. Materialize the live shared state
// under the caller's key before detaching; other aliases still need the
// source record. At capacity retain the old route and retry on later traffic,
// because forgetting a live restriction would permit an early admission.
fn WindowLimiter::expire_alias(
  self : WindowLimiter,
  bucket : String,
  now : Int64,
) -> Unit {
  guard self.aliases.get(bucket) is Some(learned) && learned.until <= now else {
    return
  }
  if self.states.get(learned.key) is Some(state) &&
    (state.until > now || state.blocked_until > now) {
    if !self.states.contains(bucket) && self.states.length() >= max_entries {
      return
    }
    self.record(bucket, state, now)
  }
  self.aliases.remove(bucket)
}

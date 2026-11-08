///|
// Sequence numbers establish permission to relax; dates are deadlines only.
// A Retry-After is an independent replacement for ordinary bucket exhaustion.
// Successes never shorten an active block, even when eligible to refresh quota.
fn reconcile(
  current : RecordedState,
  candidate : RecordedState,
) -> RecordedState {
  let blocked_until = current.blocked_until.max(candidate.blocked_until)
  if candidate.block_only {
    let restrictive = candidate.blocked_until > current.blocked_until ||
      current.value.remaining > 0
    return {
      ..candidate,
      until: blocked_until,
      blocked_until,
      restricted_by: if restrictive {
        current.restricted_by.max(candidate.restricted_by)
      } else {
        current.restricted_by
      },
      consumed_by: current.consumed_by,
    }
  }
  if candidate.restricted_by > current.restricted_by &&
    candidate.restricted_by >= current.consumed_by {
    let restrictive = candidate.value.remaining < current.value.remaining ||
      (candidate.value.remaining == 0 && candidate.until > current.until)
    return {
      ..candidate,
      blocked_until,
      restricted_by: if restrictive {
        candidate.restricted_by
      } else {
        current.restricted_by
      },
      consumed_by: current.consumed_by,
    }
  }
  if current.block_only {
    return { ..current, blocked_until, }
  }
  let restrictive = candidate.value.remaining < current.value.remaining ||
    (candidate.value.remaining == 0 && candidate.until > current.until)
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
    restricted_by: if restrictive {
      current.restricted_by.max(candidate.restricted_by)
    } else {
      current.restricted_by
    },
  }
}

///|
// A key transition is not a response and cannot authorize relaxation. Carry
// both constraints and the larger restriction watermark before switching.
fn merge(current : RecordedState, carried : RecordedState) -> RecordedState {
  let blocked_until = current.blocked_until.max(carried.blocked_until)
  let restricted_by = current.restricted_by.max(carried.restricted_by)
  let consumed_by = current.consumed_by.max(carried.consumed_by)
  if current.block_only || carried.block_only {
    let block = if carried.block_only { carried } else { current }
    return {
      ..block,
      until: blocked_until,
      blocked_until,
      restricted_by,
      consumed_by,
    }
  }
  {
    ..current,
    value: {
      remaining: current.value.remaining.min(carried.value.remaining),
      reset_at_unix_ms: current.value.reset_at_unix_ms.max(
        carried.value.reset_at_unix_ms,
      ),
    },
    until: current.until.max(carried.until),
    blocked_until,
    restricted_by,
    consumed_by,
  }
}

///|
// Unswept, fully expired state is absent: a stale deadline must not invalidate
// live quota carried to the same key.
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
fn WindowLimiter::transfer(
  self : WindowLimiter,
  key : String,
  carried : RecordedState,
  now : Int64,
) -> Unit {
  self.states[key] = match self.states.get(key) {
    Some(current) if current.until > now || current.blocked_until > now =>
      merge(current, carried)
    _ => carried
  }
}

///|
// Materialize live shared constraints before detaching. At capacity retain
// the old route: forgetting a restriction would permit an early admission.
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
    self.transfer(bucket, state, now)
  }
  self.aliases.remove(bucket)
}

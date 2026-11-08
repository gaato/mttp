///|
// Quota and Retry-After are independent constraints. Absence is the identity
// for a transfer, never a reason to delete the other key's live constraint.
fn merge_quota(a : RecordedQuota?, b : RecordedQuota?) -> RecordedQuota? {
  match (a, b) {
    (None, _) => b
    (_, None) => a
    (Some(a), Some(b)) =>
      Some({
        value: {
          remaining: a.value.remaining.min(b.value.remaining),
          reset_at_unix_ms: a.value.reset_at_unix_ms.max(
            b.value.reset_at_unix_ms,
          ),
        },
        until: a.until.max(b.until),
        restricted_by: a.restricted_by.max(b.restricted_by),
        consumed_by: a.consumed_by.max(b.consumed_by),
      })
  }
}

///|
fn merge_block(a : RecordedBlock?, b : RecordedBlock?) -> RecordedBlock? {
  match (a, b) {
    (None, _) => b
    (_, None) => a
    (Some(a), Some(b)) =>
      Some({
        ..(if b.until > a.until { b } else { a }),
        sequence: a.sequence.max(b.sequence),
      })
  }
}

///|
fn merge(a : RecordedState, b : RecordedState) -> RecordedState {
  {
    quota: merge_quota(a.quota, b.quota),
    block: merge_block(a.block, b.block),
  }
}

///|
// A response updates exactly one axis. Unlike a stored key snapshot, it
// cannot be empty or be mistaken for a transfer of both constraints.
priv enum WindowUpdate {
  Quota(RecordedQuota)
  Block(RecordedBlock)
}

///|
// Only an actual response, never a key transfer, may authorize relaxation.
// Keep active blocks conservative; an eligible Retry-After response may
// replace earlier ordinary exhaustion without erasing a newer quota window.
fn reconcile(
  current : RecordedState,
  update : WindowUpdate,
  sequence : Int64,
) -> RecordedState {
  let quota_sequence = current.quota.map(q => q.restricted_by).unwrap_or(0L)
  let consumed = current.quota.map(q => q.consumed_by).unwrap_or(0L)
  let block_sequence = current.block.map(b => b.sequence).unwrap_or(0L)
  let eligible = sequence > quota_sequence.max(block_sequence) &&
    sequence >= consumed
  let quota = match update {
    Block(_) => if eligible { None } else { current.quota }
    Quota(next) =>
      match current.quota {
        None => if eligible { Some(next) } else { None }
        Some(old) => {
          let restrictive = next.value.remaining < old.value.remaining ||
            (next.value.remaining == 0 && next.until > old.until)
          if eligible {
            Some({
              ..next,
              restricted_by: if restrictive {
                sequence
              } else {
                old.restricted_by
              },
              consumed_by: old.consumed_by,
            })
          } else {
            merge_quota(
              Some(old),
              Some({
                ..next,
                restricted_by: if restrictive {
                  sequence
                } else {
                  old.restricted_by
                },
              }),
            )
          }
        }
      }
  }
  let block = match update {
    Block(block) => merge_block(current.block, Some(block))
    Quota(_) => current.block
  }
  { quota, block, }
}

///|
fn RecordedState::live(self : RecordedState, now : Int64) -> RecordedState {
  {
    quota: self.quota.filter(q => q.until > now),
    block: self.block.filter(b => b.until > now),
  }
}

///|
fn RecordedState::empty(self : RecordedState) -> Bool {
  self.quota is None && self.block is None
}

///|
fn WindowLimiter::prune(
  self : WindowLimiter,
  key : String,
  now : Int64,
) -> RecordedState? {
  let live = self.states.get(key).map(s => s.live(now)).filter(s => !s.empty())
  match live {
    Some(state) => self.states[key] = state
    None => self.states.remove(key)
  }
  live
}

///|
fn WindowLimiter::record(
  self : WindowLimiter,
  key : String,
  candidate : WindowUpdate,
  sequence : Int64,
  now : Int64,
) -> Unit {
  let current = self.states
    .get(key)
    .map(s => s.live(now))
    .unwrap_or({ quota: None, block: None, })
  self.states[key] = reconcile(current, candidate, sequence)
}

///|
fn WindowLimiter::transfer(
  self : WindowLimiter,
  key : String,
  carried : RecordedState,
  now : Int64,
) -> Unit {
  let current = self.states
    .get(key)
    .map(s => s.live(now))
    .unwrap_or({ quota: None, block: None, })
  self.states[key] = merge(current, carried.live(now))
}

///|
// Expiry uses the same constraint join as explicit alias changes. At capacity
// retain the old route until both live constraints can be carried safely.
fn WindowLimiter::expire_alias(
  self : WindowLimiter,
  bucket : String,
  now : Int64,
) -> Unit {
  guard self.aliases.get(bucket) is Some(learned) && learned.until <= now else {
    return
  }
  if self.states.get(learned.key).map(s => s.live(now)).filter(s => !s.empty())
    is Some(state) {
    if !self.states.contains(bucket) && self.states.length() >= max_entries {
      return
    }
    self.transfer(bucket, state, now)
  }
  self.aliases.remove(bucket)
}

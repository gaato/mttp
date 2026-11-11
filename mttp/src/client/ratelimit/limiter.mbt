///|
priv struct BucketGate {
  gate : &@rt.Gate
  mut holders : Int32
  mut waiters : Int32
}

///|
priv struct RecordedQuota {
  value : RateLimitState
  until : Int64
  restricted_by : Int64
  consumed_by : Int64
}

///|
priv struct RecordedBlock {
  until : Int64
  reset_at_unix_ms : Int64
  sequence : Int64
}

///|
priv struct RecordedState {
  quota : RecordedQuota?
  block : RecordedBlock?
}

///|
priv struct Admissions {
  admission : @client.Admission
  group : String
  holding : Bool
}

///|
priv struct Alias {
  key : String
  until : Int64
}

///|
let states_sweep_floor : Int32 = 64

///|
let states_sweep_interval_ms : Int64 = 60_000L

///|
let max_server_wait_ms : Int32 = 3_600_000

///|
let max_entries : Int32 = 4096

///|
/// A fixed-window limiter on an injected Clock, with optional FIFO gates.
/// Server resets and Retry-After are capped at one hour. Each map holds at
/// most 4096 entries; expired entries are swept, and a new live entry beyond
/// that bound raises TransportError(TooLarge(4096)): Pool on acquisition,
/// Unknown when recording a response, since that request was already sent.
pub struct WindowLimiter {
  priv clock : &@rt.Clock
  priv parse : (@mttp.Headers, Int64) -> RateLimitState?
  priv states : Map[String, RecordedState]
  priv admissions : Map[Int64, Admissions]
  priv mut sequence : Int64
  priv mut states_sweep_at : Int32
  priv mut states_swept_at_ms : Int64
  priv gate : (() -> &@rt.Gate)?
  priv gates : Map[String, BucketGate]
  priv pace : (String) -> Pace
  priv server_key : ((String, @mttp.Headers) -> String?)?
  priv aliases : Map[String, Alias]
  priv next_admit_at : Map[String, Int64]
  priv scope : (Int32, @mttp.Headers) -> LimitScope
  priv global : GlobalWindow?
  priv default_retry_after_ms : Int32?
  priv mut global_window_start : Int64?
  priv mut global_count : Int32
  priv mut global_blocked_until : Int64?
  priv mut wall : Int64
  priv mut elapsed : Int64
}

///|
/// Creates a limiter using an API-specific response-header parser.
/// `pace` selects a group on acquisition; its Admission retains that group
/// until release, including when server aliases change in the meantime.
/// `gate` must create a fresh, capacity-one FIFO Gate per group; it is held
/// until release. With a gate, queued callers in a group are FIFO; without
/// one, the first caller resumed by the scheduler wins. Independent groups
/// do not promise global FIFO order.
/// `server_key` shares a response window between buckets. Learned aliases
/// expire after one hour even if another bucket keeps refreshing the state.
/// Quota expiry does not expire an alias. Responses may relax quota only
/// when their Admission sequence exceeds the independent quota and block
/// authority watermarks and does not precede later local consumption. Reset timestamps
/// are deadlines, not response ordering. Retry-After blocks are independent
/// of ordinary quota and survive responses without being shortened.
/// Each key stores quota and block separately; expiring or transferring one
/// never deletes the other. Alias joins take the stricter bound on each axis.
/// Alias changes and expiry carry live constraints before switching keys:
/// they cannot drop a block, raise quota or discard its watermarks. If
/// expiry cannot allocate the fallback state at capacity, the old route is
/// retained until transfer has room or its constraints expire.
/// `scope` classifies 429s; absent it, `global_block` selects Global/Bucket.
/// Nonpositive global windows impose no limit; negative pacing/fallback
/// delays mean zero. Parsed and fallback server waits are capped at one hour.
///
/// Clock exposes wall time, not a monotonic instant. Internally deadlines use
/// nondecreasing elapsed time: backward wall steps add no time, and completed
/// sleeps advance it by at least their duration, without adding overlapping
/// sleeps twice. Wall time is used only to interpret and report server dates.
pub fn WindowLimiter::new(
  clock : &@rt.Clock,
  parse : (@mttp.Headers, Int64) -> RateLimitState?,
  gate? : () -> &@rt.Gate,
  pace? : (String) -> Pace,
  server_key? : (String, @mttp.Headers) -> String?,
  scope? : (Int32, @mttp.Headers) -> LimitScope,
  global? : GlobalWindow,
  global_block? : (@mttp.Headers) -> Bool,
  default_retry_after_ms? : Int32,
) -> WindowLimiter {
  let now = clock.now_unix_ms()
  {
    clock,
    parse,
    gate,
    server_key,
    states: Map([]),
    admissions: Map([]),
    sequence: 0L,
    aliases: Map([]),
    gates: Map([]),
    next_admit_at: Map([]),
    states_sweep_at: states_sweep_floor,
    states_swept_at_ms: now,
    pace: pace.unwrap_or(bucket => { group: bucket, min_interval_ms: 0, }),
    scope: match (scope, global_block) {
      (Some(scope), _) => scope
      (None, Some(is_global)) =>
        (_, headers) => if is_global(headers) { Global } else { Bucket }
      _ => (_, _) => Bucket
    },
    global: match global {
      Some(window) if window.limit > 0 && window.window_ms > 0 => Some(window)
      _ => None
    },
    default_retry_after_ms: default_retry_after_ms.map(ms => {
      ms.max(0).min(max_server_wait_ms)
    }),
    global_window_start: None,
    global_count: 0,
    global_blocked_until: None,
    wall: now,
    elapsed: now,
  }
}

///|
fn WindowLimiter::now(self : WindowLimiter) -> Int64 {
  let wall = self.clock.now_unix_ms()
  if wall > self.wall {
    let delta = if self.wall < 0L && wall > 9223372036854775807L + self.wall {
      9223372036854775807L
    } else {
      wall - self.wall
    }
    self.elapsed = saturating_add_i64(self.elapsed, delta)
  }
  self.wall = wall
  self.elapsed
}

///|
async fn WindowLimiter::sleep(self : WindowLimiter, ms : Int32) -> Unit {
  let until = saturating_add_ms(self.now(), ms)
  self.clock.sleep(ms)
  self.elapsed = self.now().max(until)
}

///|
fn[T] room(
  map : Map[String, T],
  key : String,
  phase~ : @mttp.Phase = Pool,
) -> Unit raise @mttp.TransportError {
  if !map.contains(key) && map.length() >= max_entries {
    raise @mttp.TransportError(
      kind=TooLarge(limit=max_entries),
      phase~,
      detail="rate-limit map capacity exceeded",
    )
  }
}

///|
fn WindowLimiter::swept_entries(self : WindowLimiter) -> Int32 {
  self.states.length() + self.aliases.length() + self.next_admit_at.length()
}

///|
fn WindowLimiter::sweep_states(
  self : WindowLimiter,
  now : Int64,
  force~ : Bool = false,
) -> Unit {
  guard force ||
    self.swept_entries() >= self.states_sweep_at ||
    delay_until(now, self.states_swept_at_ms).to_int64() >=
    states_sweep_interval_ms else {
    return
  }
  for key in self.states.keys().to_array() {
    ignore(self.prune(key, now))
  }
  let expired_aliases = []
  for bucket, learned in self.aliases {
    if learned.until <= now {
      expired_aliases.push(bucket)
    }
  }
  for bucket in expired_aliases {
    self.expire_alias(bucket, now)
  }
  let passed = []
  for group, at in self.next_admit_at {
    if at <= now {
      passed.push(group)
    }
  }
  for group in passed {
    self.next_admit_at.remove(group)
  }
  self.states_sweep_at = (self.swept_entries() * 2).max(states_sweep_floor)
  self.states_swept_at_ms = now
}

///|
fn WindowLimiter::resolve(
  self : WindowLimiter,
  bucket : String,
  now : Int64,
) -> String {
  self.expire_alias(bucket, now)
  match self.aliases.get(bucket) {
    Some(learned) => learned.key
    _ => bucket
  }
}

///|
fn WindowLimiter::join_gate(
  self : WindowLimiter,
  group : String,
  make : () -> &@rt.Gate,
) -> BucketGate raise @mttp.TransportError {
  let entry = match self.gates.get(group) {
    Some(entry) => entry
    None => {
      room(self.gates, group)
      let entry = { gate: make(), holders: 0, waiters: 0, }
      self.gates[group] = entry
      entry
    }
  }
  entry.waiters += 1
  entry
}

///|
fn WindowLimiter::leave_gate(
  self : WindowLimiter,
  group : String,
  holding~ : Bool,
) -> Unit {
  guard self.gates.get(group) is Some(entry) else { return }
  if holding {
    guard entry.holders > 0 else { return }
    entry.holders -= 1
    entry.gate.release()
  } else {
    entry.waiters -= 1
  }
  if entry.holders == 0 && entry.waiters == 0 {
    self.gates.remove(group)
  }
}

///|
/// Explicit fixed-window limiter methods.
pub extend WindowLimiter with @client.RateLimiter::{acquire, release}

///|
/// The reconciled state for this bucket (or its learned server key), showing
/// zero remaining while a Retry-After block is active. For exhausted quota
/// alongside a block, the reported reset is the longer admission wait.
/// Expired state may remain visible until the next acquire or sweep.
pub fn WindowLimiter::state(
  self : WindowLimiter,
  bucket : String,
) -> RateLimitState? {
  let now = self.now()
  self.states
  .get(self.resolve(bucket, now))
  .bind(record => {
    if record.block is Some(block) && block.until > now {
      let until = match record.quota {
        Some(quota) if quota.value.remaining == 0 =>
          block.until.max(quota.until)
        _ => block.until
      }
      Some({
        remaining: 0,
        reset_at_unix_ms: saturating_add_ms(
          self.clock.now_unix_ms(),
          delay_until(until, now),
        ),
      })
    } else if record.quota is Some(quota) {
      Some(quota.value)
    } else {
      record.block.map(block => {
        remaining: 0,
        reset_at_unix_ms: block.reset_at_unix_ms,
      })
    }
  })
}

///|
/// Waits without reserving quota. The final global, bucket and pace checks
/// commit together without suspension. Cancellation while waiting returns a
/// held gate and never consumes quota; successful acquisition needs release.
pub impl @client.RateLimiter for WindowLimiter with fn acquire(
  self,
  bucket,
  global_exempt~,
) {
  let { group, min_interval_ms, } = (self.pace)(bucket)
  let entry = self.gate.map(make => self.join_gate(group, make))
  let mut holding = false
  let mut admitted = false
  defer (if !admitted && entry is Some(_) { self.leave_gate(group, holding~) })
  if entry is Some(entry) {
    entry.gate.acquire()
    entry.waiters -= 1
    entry.holders += 1
    holding = true
  }
  for ;; {
    let now = self.now()
    self.sweep_states(now, force=self.next_admit_at.length() >= max_entries)
    let global = if global_exempt {
      Pass
    } else {
      global_step(
        now,
        blocked_until=self.global_blocked_until,
        window=self.global,
        start=self.global_window_start,
        count=self.global_count,
      )
    }
    let key = self.resolve(bucket, now)
    let state = self.prune(key, now)
    let step = bucket_step(
      state
      .bind(record => record.quota)
      .map(quota => { ..quota.value, reset_at_unix_ms: quota.until, }),
      now,
    )
    let mut delay = pace_step(self.next_admit_at.get(group), now)
    if global is Wait(ms) {
      delay = delay.max(ms)
    }
    if step is Wait(ms) {
      delay = delay.max(ms)
    }
    if state.bind(record => record.block) is Some(block) {
      delay = delay.max(delay_until(block.until, now))
    }
    if delay > 0 {
      self.sleep(delay)
      continue
    }
    if min_interval_ms > 0 {
      room(self.next_admit_at, group)
    }
    self.admission_room()
    // No permit or window is changed until all waits and refusals finish.
    if global is Admit(start~, count~) {
      self.global_window_start = Some(start)
      self.global_count = count
    }
    match step {
      Consume(value) =>
        if state is Some(record) && record.quota is Some(quota) {
          self.states[key] = {
            ..record,
            quota: Some({
              ..quota,
              value: { ..quota.value, remaining: value.remaining, },
              consumed_by: quota.consumed_by.max(self.sequence + 1L),
            }),
          }
        }
      Admit | Expired | Wait(_) => ()
    }
    if min_interval_ms > 0 {
      self.next_admit_at[group] = saturating_add_ms(now, min_interval_ms)
    }
    let admission = self.issue(bucket, group, holding~)
    admitted = true
    return admission
  }
}

///|
fn clamp_server_reset(state : RateLimitState, now : Int64) -> RateLimitState {
  {
    ..state,
    reset_at_unix_ms: state.reset_at_unix_ms.min(
      saturating_add_ms(now, max_server_wait_ms),
    ),
  }
}

///|
/// Records the head, then frees the group gate even when recording refuses
/// a new entry. Status zero leaves state unchanged. An ignored 429 changes
/// neither aliases nor state. Parsing dates uses the current Unix time;
/// waiting uses the corresponding elapsed-time deadline.
pub impl @client.RateLimiter for WindowLimiter with fn release(
  self,
  admission,
  status~,
  headers~,
) {
  let bucket = admission.bucket()
  let sequence = admission.sequence()
  guard self.admissions.get(sequence) is Some(active) &&
    active.admission.bucket() == bucket else {
    return
  }
  self.admissions.remove(sequence)
  defer (if active.holding { self.leave_gate(active.group, holding=true) })
  let now = self.now()
  self.sweep_states(
    now,
    force=self.states.length() >= max_entries ||
      self.aliases.length() >= max_entries,
  )
  if status == 0 {
    return
  }
  let scope = if status == 429 { (self.scope)(status, headers) } else { Bucket }
  if status == 429 && scope is Ignore {
    return
  }
  let named = match self.server_key {
    Some(key) => key(bucket, headers)
    None => None
  }
  let previous = self.resolve(bucket, now)
  let key = named.unwrap_or(previous)
  let carried = if previous == key {
    None
  } else {
    self.states.get(previous).map(s => s.live(now)).filter(s => !s.empty())
  }
  let wall = self.clock.now_unix_ms()
  let parsed = (self.parse)(headers, wall).map(state => {
    clamp_server_reset(state, wall)
  })
  let delay_ms = match @client.retry_after_ms(headers, now_unix_ms=wall) {
    Some(ms) => Some(ms.min(max_server_wait_ms))
    None => self.default_retry_after_ms
  }
  // release_effect uses elapsed instants here, keeping all internal windows
  // in one time domain even when the Unix clock has moved backward.
  let effect = release_effect(
    status,
    parsed=parsed.map(state => {
      ..state,
      reset_at_unix_ms: saturating_add_ms(
        now,
        delay_until(state.reset_at_unix_ms, wall),
      ),
    }),
    delay_ms~,
    scope~,
    blocked_until=self.global_blocked_until,
    now~,
  )
  // Preflight the entire transition before changing either state or alias.
  // A header without parsed quota must still carry the previous constraints.
  if effect.record is Some(_) || carried is Some(_) {
    room(self.states, key, phase=Unknown)
  }
  if named is Some(key) && key != bucket {
    room(self.aliases, bucket, phase=Unknown)
  }
  if carried is Some(state) {
    self.transfer(key, state, now)
  }
  if effect.record is Some(value) {
    let reported = if status == 429 && scope is Bucket {
      {
        ..value,
        reset_at_unix_ms: saturating_add_ms(
          wall,
          delay_until(value.reset_at_unix_ms, now),
        ),
      }
    } else {
      parsed.unwrap_or(value)
    }
    let bucket_block = status == 429 && scope is Bucket && delay_ms is Some(_)
    let candidate : WindowUpdate = if bucket_block {
      Block({
        until: value.reset_at_unix_ms,
        reset_at_unix_ms: reported.reset_at_unix_ms,
        sequence,
      })
    } else {
      Quota({
        value: { ..reported, remaining: reported.remaining.max(0), },
        until: value.reset_at_unix_ms,
        restricted_by: sequence,
        consumed_by: 0L,
      })
    }
    self.record(key, candidate, sequence, now)
  }
  if named is Some(key) {
    if key == bucket {
      self.aliases.remove(bucket)
    } else {
      self.aliases[bucket] = {
        key,
        until: saturating_add_ms(now, max_server_wait_ms),
      }
    }
  }
  self.global_blocked_until = effect.blocked_until
}

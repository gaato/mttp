///|
priv struct BucketGate {
  gate : &@rt.Gate
  mut holders : Int32
  mut waiters : Int32
}

///|
priv struct RecordedState {
  value : RateLimitState
  until : Int64
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
  priv parse : (@http.Headers, Int64) -> RateLimitState?
  priv states : Map[String, RecordedState]
  priv mut states_sweep_at : Int32
  priv mut states_swept_at_ms : Int64
  priv gate : (() -> &@rt.Gate)?
  priv gates : Map[String, BucketGate]
  priv pace : (String) -> Pace
  priv server_key : ((String, @http.Headers) -> String?)?
  priv aliases : Map[String, Alias]
  priv next_admit_at : Map[String, Int64]
  priv scope : (Int32, @http.Headers) -> LimitScope
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
/// `pace` must be pure: acquire and release must select the same group.
/// `gate` must create a fresh, capacity-one FIFO Gate per group; it is held
/// until release. With a gate, queued callers in a group are FIFO; without
/// one, the first caller resumed by the scheduler wins. Independent groups
/// do not promise global FIFO order.
/// `server_key` shares a response window between buckets. Learned aliases
/// expire after one hour even if another bucket keeps refreshing the state.
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
  parse : (@http.Headers, Int64) -> RateLimitState?,
  gate? : () -> &@rt.Gate,
  pace? : (String) -> Pace,
  server_key? : (String, @http.Headers) -> String?,
  scope? : (Int32, @http.Headers) -> LimitScope,
  global? : GlobalWindow,
  global_block? : (@http.Headers) -> Bool,
  default_retry_after_ms? : Int32,
) -> WindowLimiter {
  let now = clock.now_unix_ms()
  {
    clock,
    parse,
    gate,
    server_key,
    states: Map([]),
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
  phase~ : @http.Phase = Pool,
) -> Unit raise @http.TransportError {
  if !map.contains(key) && map.length() >= max_entries {
    raise @http.TransportError(
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
  let expired = []
  for key, state in self.states {
    if state.until <= now {
      expired.push(key)
    }
  }
  for key in expired {
    self.states.remove(key)
  }
  let orphaned = []
  for bucket, learned in self.aliases {
    if learned.until <= now || !self.states.contains(learned.key) {
      orphaned.push(bucket)
    }
  }
  for bucket in orphaned {
    self.aliases.remove(bucket)
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
  match self.aliases.get(bucket) {
    Some(learned) if learned.until > now => learned.key
    _ => bucket
  }
}

///|
fn WindowLimiter::join_gate(
  self : WindowLimiter,
  group : String,
  make : () -> &@rt.Gate,
) -> BucketGate raise @http.TransportError {
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
/// The last recorded state for this bucket (or its learned server key).
/// Expired state may remain visible until the next acquire or sweep.
pub fn WindowLimiter::state(
  self : WindowLimiter,
  bucket : String,
) -> RateLimitState? {
  self.states.get(self.resolve(bucket, self.now())).map(record => record.value)
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
    let state = self.states.get(key)
    let step = bucket_step(
      state.map(record => { ..record.value, reset_at_unix_ms: record.until, }),
      now,
    )
    let mut delay = pace_step(self.next_admit_at.get(group), now)
    if global is Wait(ms) {
      delay = delay.max(ms)
    }
    if step is Wait(ms) {
      delay = delay.max(ms)
    }
    if delay > 0 {
      self.sleep(delay)
      continue
    }
    if min_interval_ms > 0 {
      room(self.next_admit_at, group)
    }
    // No permit or window is changed until all waits and refusals finish.
    if global is Admit(start~, count~) {
      self.global_window_start = Some(start)
      self.global_count = count
    }
    match step {
      Expired => self.states.remove(key)
      Consume(value) =>
        if state is Some(record) {
          self.states[key] = {
            ..record,
            value: { ..record.value, remaining: value.remaining, },
          }
        }
      _ => ()
    }
    if min_interval_ms > 0 {
      self.next_admit_at[group] = saturating_add_ms(now, min_interval_ms)
    }
    admitted = true
    return
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
  bucket,
  status~,
  headers~,
) {
  defer self.leave_gate((self.pace)(bucket).group, holding=true)
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
  let key = named.unwrap_or(self.resolve(bucket, now))
  let wall = self.clock.now_unix_ms()
  let parsed = (self.parse)(headers, wall).map(state => {
    clamp_server_reset(state, wall)
  })
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
    delay_ms=match @client.retry_after_ms(headers, now_unix_ms=wall) {
      Some(ms) => Some(ms.min(max_server_wait_ms))
      None => self.default_retry_after_ms
    },
    scope~,
    blocked_until=self.global_blocked_until,
    now~,
  )
  if effect.record is Some(_) {
    room(self.states, key, phase=Unknown)
  }
  if named is Some(key) && key != bucket {
    room(self.aliases, bucket, phase=Unknown)
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
    self.states[key] = { value: reported, until: value.reset_at_unix_ms, }
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

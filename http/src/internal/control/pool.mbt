// The metadata of a client's idle connections: which ids are parked under
// which pool key, by User-Agent and parking time. The engine keeps the
// connections in its own table; every transition returns the ids it decided
// to close, and the engine closes them after committing the new state.

///|
/// One parked connection.
pub(all) struct Idle {
  id : Int64
  /// The User-Agent of the request that used it; reuse requires the same.
  user_agent : String?
  /// When it was parked, on the engine's clock.
  parked_at_ms : Int64
}

///|
/// The parked connections per key, with the caps that bound them.
pub(all) struct PoolState {
  /// Parked connections over all keys.
  max_total : Int32
  /// Parked connections per key; 0 or less parks nothing.
  max_per_origin : Int32
  /// How long a connection may stay parked; 0 or less parks nothing.
  idle_max_ms : Int32
  /// The parked connections per key, oldest first; a key with none has no
  /// entry, so the index is bounded by `max_total` too.
  parked : @persistent.HashMap[String, @vector.Vector[Idle]]
  /// Drained: nothing is parked any more.
  closed : Bool
}

///|
/// The state after a transition, and the ids of the connections to close.
pub(all) struct PoolChange {
  state : PoolState
  close : @vector.Vector[Int64]
}

///|
/// An empty pool.
pub fn PoolState::new(
  max_total~ : Int32 = 256,
  max_per_origin~ : Int32,
  idle_max_ms~ : Int32,
) -> PoolState {
  {
    max_total,
    max_per_origin,
    idle_max_ms,
    parked: @persistent.HashMap::new(),
    closed: false,
  }
}

///|
/// Parked connections over all keys.
pub fn PoolState::count(self : PoolState) -> Int32 {
  self.parked.fold(init=0, (count, _, entries) => count + entries.length())
}

///|
/// Closes every connection parked for `idle_max_ms` or longer at `now`. A
/// clock that went backward expires nothing that was parked later than
/// `now`.
pub fn PoolState::sweep(self : PoolState, now~ : Int64) -> PoolChange {
  let mut parked = self.parked
  let closed = []
  for origin, entries in self.parked {
    let kept = entries.filter(entry => {
      let age = now - entry.parked_at_ms
      let expired = now >= entry.parked_at_ms &&
        (age < 0L || age >= self.idle_max_ms.to_int64())
      if expired {
        closed.push(entry.id)
      }
      !expired
    })
    if kept.length() != entries.length() {
      parked = if kept.is_empty() {
        parked.remove(origin)
      } else {
        parked.add(origin, kept)
      }
    }
  }
  { state: { ..self, parked, }, close: @vector.Vector(closed[:]), }
}

///|
/// Sweeps, then takes the newest connection parked under `origin` with the
/// same `user_agent`, if any. The id is the caller's to use; the change
/// lists what the sweep closed.
pub fn PoolState::take(
  self : PoolState,
  origin : String,
  user_agent : String?,
  now~ : Int64,
) -> (PoolChange, Int64?) {
  let change = self.sweep(now~)
  guard change.state.parked.get(origin) is Some(entries) else {
    return (change, None)
  }
  for i = entries.length() - 1; i >= 0; i = i - 1 {
    if entries[i].user_agent == user_agent {
      let kept = entries.filter(entry => entry.id != entries[i].id)
      let parked = if kept.is_empty() {
        change.state.parked.remove(origin)
      } else {
        change.state.parked.add(origin, kept)
      }
      return (
        { ..change, state: { ..change.state, parked, }, },
        Some(entries[i].id),
      )
    }
  }
  (change, None)
}

///|
/// Sweeps, then parks `entry` under `origin` when both caps leave room and
/// the pool is open; otherwise `entry` is among the ids to close.
pub fn PoolState::put(
  self : PoolState,
  origin : String,
  entry : Idle,
  now~ : Int64,
) -> PoolChange {
  let change = self.sweep(now~)
  let entries = change.state.parked.get(origin).unwrap_or(@vector.Vector::new())
  if self.closed ||
    self.max_per_origin <= 0 ||
    self.idle_max_ms <= 0 ||
    change.state.count() >= self.max_total ||
    entries.length() >= self.max_per_origin {
    return { ..change, close: change.close.push(entry.id), }
  }
  {
    ..change,
    state: {
      ..change.state,
      parked: change.state.parked.add(origin, entries.push(entry)),
    },
  }
}

///|
/// Closes the pool: every parked id is to be closed, and later `put`s close
/// their entry at once.
pub fn PoolState::drain(self : PoolState) -> PoolChange {
  let close = []
  for _, entries in self.parked {
    for entry in entries {
      close.push(entry.id)
    }
  }
  {
    state: { ..self, closed: true, parked: @persistent.HashMap::new(), },
    close: @vector.Vector(close[:]),
  }
}

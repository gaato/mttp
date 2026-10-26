///|
pub(all) struct Idle {
  id : Int64
  user_agent : String?
  parked_at_ms : Int64
}

///|
pub(all) struct PoolState {
  max_total : Int32
  max_per_origin : Int32
  idle_max_ms : Int32
  parked : @persistent.HashMap[String, @vector.Vector[Idle]]
  closed : Bool
}

///|
pub(all) struct PoolChange {
  state : PoolState
  close : @vector.Vector[Int64]
}

///|
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
pub fn PoolState::count(self : PoolState) -> Int32 {
  self.parked.fold(init=0, (count, _, entries) => count + entries.length())
}

///|
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

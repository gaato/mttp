///|
/// Resource handles belong here; the persistent control state contains IDs only.
pub(all) struct IdlePool[C] {
  mut control : @control.PoolState
  resources : Map[Int64, C]
  mut next_id : Int64
}

///|
pub fn[C] IdlePool::new(
  max_total~ : Int32 = 256,
  max_per_origin~ : Int32,
  idle_max_ms~ : Int32,
) -> IdlePool[C] {
  {
    control: @control.PoolState::new(max_total~, max_per_origin~, idle_max_ms~),
    resources: Map([]),
    next_id: 0L,
  }
}

///|
fn[C] IdlePool::apply(
  self : IdlePool[C],
  change : @control.PoolChange,
) -> Array[C] {
  self.control = change.state
  let close = []
  for id in change.close {
    if self.resources.get(id) is Some(conn) {
      self.resources.remove(id)
      close.push(conn)
    }
  }
  close
}

///|
pub fn[C] IdlePool::take(
  self : IdlePool[C],
  origin : String,
  user_agent : String?,
  now~ : Int64,
) -> (C?, Array[C]) {
  let (change, id) = self.control.take(origin, user_agent, now~)
  let expired = self.apply(change)
  let conn = match id {
    None => None
    Some(id) => {
      let conn = self.resources.get(id)
      self.resources.remove(id)
      conn
    }
  }
  (conn, expired)
}

///|
pub fn[C] IdlePool::put(
  self : IdlePool[C],
  origin : String,
  user_agent : String?,
  conn : C,
  now~ : Int64,
) -> Array[C] {
  self.next_id += 1L
  let id = self.next_id
  self.resources[id] = conn
  self.apply(
    self.control.put(origin, { id, user_agent, parked_at_ms: now, }, now~),
  )
}

///|
pub fn[C] IdlePool::drain(self : IdlePool[C]) -> Array[C] {
  self.apply(self.control.drain())
}

///|
pub fn[C] IdlePool::count(self : IdlePool[C]) -> Int32 {
  self.control.count()
}

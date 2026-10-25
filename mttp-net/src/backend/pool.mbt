///|

///|
/// A keep-alive connection parked between requests to one origin.
priv struct IdleConn[C] {
  conn : C
  user_agent : String?
  parked_at_ms : Int64
}

///|
/// Parked keep-alive connections per origin. Generic over the connection so
/// the bookkeeping runs without sockets in tests; methods hand back the
/// connections the caller must close.
priv struct IdlePool[C] {
  max_total : Int32
  max_per_origin : Int32
  idle_max_ms : Int32
  parked : Map[String, Array[IdleConn[C]]]
  mut closed : Bool
}

///|
fn[C] IdlePool::new(
  max_total~ : Int32 = 256,
  max_per_origin~ : Int32,
  idle_max_ms~ : Int32,
) -> IdlePool[C] {
  { max_total, max_per_origin, idle_max_ms, parked: Map([]), closed: false, }
}

///|
/// Takes out every connection that outlived `idle_max_ms`, across all origins,
/// and forgets origins left without connections. The pool holds at most
/// `max_per_origin` connections per origin, so a full pass stays cheap.
fn[C] IdlePool::sweep(self : IdlePool[C], now~ : Int64) -> Array[C] {
  let expired = []
  let emptied = []
  for origin, parked in self.parked {
    for i = parked.length() - 1; i >= 0; i = i - 1 {
      if now - parked[i].parked_at_ms >= self.idle_max_ms.to_int64() {
        expired.push(parked.remove(i).conn)
      }
    }
    if parked.is_empty() {
      emptied.push(origin)
    }
  }
  for origin in emptied {
    self.parked.remove(origin)
  }
  expired
}

///|
/// Takes the newest connection to `origin` parked with `user_agent`. Expired
/// connections of every origin are handed back alongside.
fn[C] IdlePool::take(
  self : IdlePool[C],
  origin : String,
  user_agent : String?,
  now~ : Int64,
) -> (C?, Array[C]) {
  let expired = self.sweep(now~)
  guard self.parked.get(origin) is Some(parked) else { return (None, expired) }
  for i = parked.length() - 1; i >= 0; i = i - 1 {
    if parked[i].user_agent == user_agent {
      let idle = parked.remove(i)
      if parked.is_empty() {
        self.parked.remove(origin)
      }
      return (Some(idle.conn), expired)
    }
  }
  (None, expired)
}

///|
/// Parks `conn`, or hands it back when the pool is closed, reuse is disabled,
/// or `origin` already holds `max_per_origin` young connections. Expired
/// connections of every origin are handed back alongside, before the cap is
/// applied.
fn[C] IdlePool::put(
  self : IdlePool[C],
  origin : String,
  user_agent : String?,
  conn : C,
  now~ : Int64,
) -> Array[C] {
  let rejected = self.sweep(now~)
  if self.closed ||
    self.max_per_origin <= 0 ||
    self.idle_max_ms <= 0 ||
    self.count() >= self.max_total {
    rejected.push(conn)
    return rejected
  }
  let parked = self.parked.get_or_init(origin, () => [])
  if parked.length() >= self.max_per_origin {
    rejected.push(conn)
    return rejected
  }
  parked.push({ conn, user_agent, parked_at_ms: now, })
  rejected
}

///|
/// Closes the pool and hands back every parked connection.
fn[C] IdlePool::drain(self : IdlePool[C]) -> Array[C] {
  self.closed = true
  let conns = []
  for _, parked in self.parked {
    for idle in parked {
      conns.push(idle.conn)
    }
  }
  self.parked.clear()
  conns
}

///|
fn[C] IdlePool::count(self : IdlePool[C]) -> Int32 {
  let mut total = 0
  for _, parked in self.parked {
    total += parked.length()
  }
  total
}

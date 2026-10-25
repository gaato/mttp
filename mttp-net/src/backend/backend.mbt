///|
/// A socket backend using mttp's bounded HTTP/1 codec and verified system
/// TLS roots. A response owns its connection until consumed or closed.
/// This backend sends one exchange; compose FollowRedirects for redirects.
/// Native and moonrun wasm are supported. Proxy routing is not yet provided.
pub struct H1Backend {
  priv clock : &@clock.Clock
  priv limits : Timeouts
  priv head_limits : @h1.Limits
  priv body_ceiling : Int32?
  priv pool : IdlePool[Wire]
  priv slots : Slots
}

///|
/// Creates a backend with the mature 30-second timeout and per-origin idle
/// pool defaults. Per-request options override attempt and read-idle budgets.
/// Connection caps bound active exchanges; a parked socket holds no slot.
pub fn H1Backend::new(
  timeout_ms~ : Int32 = 30000,
  connect_timeout_ms? : Int32,
  write_timeout_ms? : Int32,
  read_timeout_ms? : Int32,
  pool_timeout_ms? : Int32,
  max_connections? : Int32,
  max_connections_per_origin? : Int32,
  max_idle_connections~ : Int32 = 256,
  max_idle_per_origin~ : Int32 = 4,
  idle_max_ms~ : Int32 = 10000,
  max_body_bytes? : Int32,
  head_limits~ : @h1.Limits = @h1.Limits::default(),
  clock~ : &@clock.Clock = @runtime.AsyncClock::new(),
) -> H1Backend {
  {
    clock,
    limits: {
      total: timeout_ms,
      pool: pool_timeout_ms.unwrap_or(timeout_ms),
      connect: connect_timeout_ms.unwrap_or(timeout_ms),
      write: write_timeout_ms.unwrap_or(timeout_ms),
      read: read_timeout_ms.unwrap_or(timeout_ms),
    },
    head_limits,
    body_ceiling: max_body_bytes,
    pool: IdlePool::new(
      max_total=max_idle_connections,
      max_per_origin=max_idle_per_origin,
      idle_max_ms~,
    ),
    slots: Slots::new(
      max_total?=max_connections,
      max_per_origin?=max_connections_per_origin,
    ),
  }
}

///|
/// Closes parked connections and refuses queued/future calls. In-flight
/// responses retain ownership; finishing them closes rather than parks them.
pub fn H1Backend::close(self : H1Backend) -> Unit {
  for wire in self.pool.drain() {
    wire.close()
  }
  self.slots.refuse_waiting()
}

///|
/// Returns the number of parked sockets across origins.
pub fn H1Backend::idle_connections(self : H1Backend) -> Int32 {
  self.pool.count()
}

///|
/// Closes through the common backend interface.
pub impl @client.Backend for H1Backend with fn close(self) {
  self.close()
}

///|
/// Sends through the common backend interface.
pub impl @client.Backend for H1Backend with fn send(self, request, options) {
  self.send(request, options)
}

///|
fn H1Backend::release(
  self : H1Backend,
  key : String,
  agent : String?,
  wire : Wire,
  reusable : Bool,
) -> Unit {
  if reusable && wire.pending.is_empty() {
    for
      rejected in self.pool.put(key, agent, wire, now=self.clock.now_unix_ms()) {
      rejected.close()
    }
  } else {
    wire.close()
  }
  self.slots.release(key)
}

///|
fn connection_token(headers : @model.Headers, token : String) -> Bool {
  headers
  .get_all("connection")
  .iter()
  .any(value => {
    value
    .split(",")
    .any(part => part.trim(chars=" \t").to_owned().to_lower() == token)
  })
}

///|
fn replayable(request : @model.Request) -> Bool {
  request.body.is_replayable() &&
  (@model.is_idempotent(request) || request.headers.contains("idempotency-key"))
}

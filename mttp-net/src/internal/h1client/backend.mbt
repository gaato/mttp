///|
/// HTTP/1 orchestration over explicit connection, scheduling and time ports.
/// A response owns its connection until consumed or closed. TLS trust belongs
/// to the supplied Dialer; this engine never reads a host environment itself.
pub(all) struct Client {
  dialer : &@connection.Dialer
  timer : &@clock.Timer
  coordination : &@connection.Coordination
  clock : &@clock.Clock
  limits : Timeouts
  head_limits : @h1.Limits
  body_ceiling : Int32?
  pool : IdlePool[Wire]
  slots : Slots
  proxies : Proxies
}

///|
/// Creates a backend with the mature 30-second timeout and per-origin idle
/// pool defaults. Per-request options override attempt and read-idle budgets.
/// Connection caps bound active exchanges; a parked socket holds no slot.
/// An explicit proxy wins over the environment. Otherwise trust_env (true
/// by default) reads HTTP(S)/ALL_PROXY and NO_PROXY once at construction;
/// lowercase settings win, and CGI ignores uppercase HTTP_PROXY.
pub fn Client::new(
  dialer~ : &@connection.Dialer,
  timer~ : &@clock.Timer,
  coordination~ : &@connection.Coordination,
  lookup~ : (String) -> String? = _ => None,
  proxy? : String,
  trust_env~ : Bool = true,
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
  clock~ : &@clock.Clock,
) -> Client {
  {
    proxies: configure_proxies(proxy, trust_env~, lookup),
    dialer,
    timer,
    coordination,
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
      coordination~,
      max_total?=max_connections,
      max_per_origin?=max_connections_per_origin,
    ),
  }
}

///|
/// Closes parked connections and refuses queued/future calls. In-flight
/// responses retain ownership; finishing them closes rather than parks them.
pub fn Client::close(self : Client) -> Unit {
  for wire in self.pool.drain() {
    wire.close()
  }
  self.slots.refuse_waiting()
}

///|
/// Returns the number of parked sockets across origins.
pub fn Client::idle_connections(self : Client) -> Int32 {
  self.pool.count()
}

///|
pub fn Client::release(
  self : Client,
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
pub fn connection_token(headers : @model.Headers, token : String) -> Bool {
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
pub fn replayable(request : @model.Request) -> Bool {
  request.body.is_replayable() &&
  (@model.is_idempotent(request) || request.headers.contains("idempotency-key"))
}

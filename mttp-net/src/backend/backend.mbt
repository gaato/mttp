///|
using @engine {type IdlePool, type Slots, type Wire, type Proxies}

///|
/// A socket backend using mttp's bounded HTTP/1 codec and verified system
/// TLS roots. A response owns its connection until consumed or closed.
/// This backend sends one exchange; compose FollowRedirects for redirects.
/// Native and moonrun wasm are supported. HTTP(S) proxies forward HTTP
/// requests and tunnel HTTPS requests with end-to-end TLS.
pub struct H1Backend {
  priv dialer : &@connection.Dialer
  priv timer : &@clock.Timer
  priv coordination : &@connection.Coordination
  priv clock : &@clock.Clock
  priv limits : Timeouts
  priv head_limits : @h1.Limits
  priv body_ceiling : Int32?
  priv pool : IdlePool[Wire]
  priv slots : Slots
  priv proxies : Proxies
}

///|
/// Creates a backend with the mature 30-second timeout and per-origin idle
/// pool defaults. Per-request options override attempt and read-idle budgets.
/// Connection caps bound active exchanges; a parked socket holds no slot.
/// An explicit proxy wins over the environment. Otherwise trust_env (true
/// by default) reads HTTP(S)/ALL_PROXY and NO_PROXY once at construction;
/// lowercase settings win, and CGI ignores uppercase HTTP_PROXY.
pub fn H1Backend::new(
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
  clock~ : &@clock.Clock = @runtime.AsyncClock::new(),
) -> H1Backend {
  let coordination = @runtime.RuntimeCoordination::new()
  {
    dialer: @socket_conn.TcpDialer::new(),
    timer: @runtime.ClockTimer::new(clock~),
    coordination,
    proxies: @engine.configure_proxies(proxy, trust_env~, @env.get_env_var),
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
fn H1Backend::engine(self : H1Backend) -> @engine.Client {
  {
    dialer: self.dialer,
    timer: self.timer,
    coordination: self.coordination,
    clock: self.clock,
    limits: self.limits,
    head_limits: self.head_limits,
    body_ceiling: self.body_ceiling,
    pool: self.pool,
    slots: self.slots,
    proxies: self.proxies,
  }
}

///|
/// Runs one exchange through the shared engine; the response owns its body.
pub async fn H1Backend::send(
  self : H1Backend,
  request : @model.Request,
  options : @client.RequestOptions,
) -> @model.Response raise @model.TransportError {
  self.engine().send(request, options)
}

///|
using @engine {type Timeouts}

///|
/// A platform backend: bounded HTTP/1 sockets on native/wasm, fetch on JS.
/// It performs one exchange; compose FollowRedirects and Cookies explicitly.
pub struct AsyncBackend {
  priv inner : &@client.Backend
  priv idle : () -> Int32
}

///|
// Socket-specific settings stay in the shared constructor contract on JS,
// where the platform controls these resources.
#warnings("-unused_field")
priv struct Settings {
  proxy : String?
  trust_env : Bool
  clock : &@clock.Clock
  timeouts : Timeouts
  max_connections : Int32?
  max_connections_per_origin : Int32?
  max_idle_connections : Int32
  max_idle_per_origin : Int32
  idle_max_ms : Int32
  max_body_bytes : Int32?
  head_limits : @h1.Limits
}

///|
/// Creates the platform backend. Socket options match H1Backend. On JS the
/// platform owns proxies, idle pooling, header bounds and content decoding;
/// explicit proxy URLs are refused. Stream uploads are buffered to 16 MiB.
/// Active connection caps, total/read deadlines and decoded body limits are
/// enforced on every platform. JS network failures have phase Unknown.
pub fn AsyncBackend::new(
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
) -> AsyncBackend {
  platform_backend({
    proxy,
    trust_env,
    clock,
    timeouts: {
      total: timeout_ms,
      connect: connect_timeout_ms.unwrap_or(timeout_ms),
      write: write_timeout_ms.unwrap_or(timeout_ms),
      read: read_timeout_ms.unwrap_or(timeout_ms),
      pool: pool_timeout_ms.unwrap_or(timeout_ms),
    },
    max_connections,
    max_connections_per_origin,
    max_idle_connections,
    max_idle_per_origin,
    idle_max_ms,
    max_body_bytes,
    head_limits,
  })
}

///|
/// Sends one exchange and transfers response ownership to the caller.
pub async fn AsyncBackend::send(
  self : AsyncBackend,
  request : @model.Request,
  options : @client.RequestOptions,
) -> @model.Response raise @model.TransportError {
  self.inner.send(request, options)
}

///|
/// Closes idle resources and refuses future calls; responses own their bodies.
pub fn AsyncBackend::close(self : AsyncBackend) -> Unit {
  self.inner.close()
}

///|
/// Number of sockets in our idle pool, or zero on JS (platform-owned pooling).
pub fn AsyncBackend::idle_connections(self : AsyncBackend) -> Int32 {
  (self.idle)()
}

///|
/// Implements the common single-exchange backend contract.
pub impl @client.Backend for AsyncBackend with fn send(self, request, options) {
  self.send(request, options)
}

///|
/// Releases resources through the common interface.
pub impl @client.Backend for AsyncBackend with fn close(self) {
  self.close()
}

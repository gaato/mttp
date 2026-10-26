///|
/// Portable HTTP/1 engine. The supplied ports own runtime operations;
/// the engine owns connections until their response body is consumed/closed.
pub struct H1Backend {
  priv inner : @engine.Client
}

///|
/// Defaults match the socket facade. Environment routing is an explicit
/// snapshot: lookup is called only during construction, never while sending.
pub fn H1Backend::new(
  dialer~ : &@connection.Dialer,
  clock~ : &@clock.Clock,
  timer~ : &@clock.Timer,
  coordination~ : &@connection.Coordination,
  proxy? : String,
  lookup~ : (String) -> String? = _ => None,
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
) -> H1Backend {
  {
    inner: @engine.Client::new(
      dialer~,
      clock~,
      timer~,
      coordination~,
      proxy?,
      lookup~,
      trust_env=true,
      timeout_ms~,
      connect_timeout_ms?,
      write_timeout_ms?,
      read_timeout_ms?,
      pool_timeout_ms?,
      max_connections?,
      max_connections_per_origin?,
      max_idle_connections~,
      max_idle_per_origin~,
      idle_max_ms~,
      max_body_bytes?,
      head_limits~,
    ),
  }
}

///|
/// Runs one exchange and transfers response-body ownership to the caller.
pub async fn H1Backend::send(
  self : H1Backend,
  request : @model.Request,
  options : @httpclient.RequestOptions,
) -> @model.Response raise @model.TransportError {
  self.inner.send(request, options)
}

///|
/// Refuses queued/future calls and closes idle connections; active bodies retain ownership.
pub fn H1Backend::close(self : H1Backend) -> Unit {
  self.inner.close()
}

///|
/// Counts currently parked connections across origins.
pub fn H1Backend::idle_connections(self : H1Backend) -> Int32 {
  self.inner.idle_connections()
}

///|
/// Sends through the common single-exchange backend contract.
pub impl @httpclient.Backend for H1Backend with fn send(self, request, options) {
  self.send(request, options)
}

///|
/// Closes through the common backend contract.
pub impl @httpclient.Backend for H1Backend with fn close(self) {
  self.close()
}

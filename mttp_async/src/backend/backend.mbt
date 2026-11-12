///|
/// One exchange over HTTP/1 sockets on native/wasm, or host fetch on JS.
/// Socket responses are decoded unless the request sets Accept-Encoding.
/// Compose redirects, retries and cookies explicitly above this backend.
pub struct AsyncBackend {
  priv inner : &@mttp.Backend
  priv idle : () -> Int32
}

///|
/// Creates a backend. With no config, socket targets read proxy variables
/// from the process environment once. An explicit config is used verbatim;
/// its ProxyConfig::none disables environment proxies. On JS only
/// config.max_body_bytes applies; trust and socket settings are ignored.
/// `clock` defaults to AsyncClock; `timer` defaults to ClockTimer on that
/// clock. Socket pool expiry and deadlines use these ports; fetch uses them
/// for upload, head and body deadlines (host pooling remains outside them).
pub fn AsyncBackend::new(
  config? : @h1client.ClientConfig,
  trust~ : @trust.Trust = System,
  clock? : &@rt.Clock,
  timer? : &@rt.Timer,
) -> AsyncBackend {
  let clock = clock.unwrap_or_else(() => @runtime.AsyncClock::new())
  let timer = timer.unwrap_or_else(() => @runtime.ClockTimer::new(clock~))
  platform_backend(config, trust, clock, timer)
}

///|
/// Sends one request, transferring ownership of the response to its caller.
pub async fn AsyncBackend::send(
  self : AsyncBackend,
  request : @mttp.Request,
  options : @mttp.SendOptions,
) -> @mttp.Response raise @mttp.TransportError {
  self.inner.send(request, options)
}

///|
/// Closes the backend idempotently and refuses subsequent sends.
pub fn AsyncBackend::close(self : AsyncBackend) -> Unit {
  self.inner.close()
}

///|
/// Counts parked socket connections; JS pooling belongs to the host (zero).
pub fn AsyncBackend::idle_connections(self : AsyncBackend) -> Int32 {
  (self.idle)()
}

///|
/// Implements the portable single-exchange transport seam.
pub impl @mttp.Backend for AsyncBackend with fn send(self, request, options) {
  self.send(request, options)
}

///|
/// Releases the backend through the portable interface.
pub impl @mttp.Backend for AsyncBackend with fn close(self) {
  self.close()
}

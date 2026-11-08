///|
/// One exchange over HTTP/1 sockets on native/wasm, or host fetch on JS.
/// Socket responses are decoded unless the request sets Accept-Encoding.
/// Compose redirects, retries and cookies explicitly above this backend.
pub struct AsyncBackend {
  priv inner : &@http.Backend
  priv idle : () -> Int32
}

///|
/// Creates a backend. With no config, socket targets read proxy variables
/// from the process environment once. An explicit config is used verbatim;
/// its ProxyConfig::none disables environment proxies. On JS only
/// config.max_body_bytes applies; trust and socket settings are ignored.
pub fn AsyncBackend::new(
  config? : @h1client.ClientConfig,
  trust~ : @http_async.Trust = System,
) -> AsyncBackend {
  platform_backend(config, trust)
}

///|
/// Sends one request, transferring ownership of the response to its caller.
pub async fn AsyncBackend::send(
  self : AsyncBackend,
  request : @http.Request,
  options : @http.SendOptions,
) -> @http.Response raise @http.TransportError {
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
pub impl @http.Backend for AsyncBackend with fn send(self, request, options) {
  self.send(request, options)
}

///|
/// Releases the backend through the portable interface.
pub impl @http.Backend for AsyncBackend with fn close(self) {
  self.close()
}

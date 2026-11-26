// The entry of gaato/mttp_ng: the network as gaato/mttp's `backend()` has
// it, with HTTP/2 where the server speaks it.

///|
/// gaato/mttp's network over this module's engines: an
/// `@h2client.H2Backend` under `@codings.Decompress`, so responses arrive
/// decoded (gzip, deflate, br, zstd) and an `Accept-Encoding` is offered
/// unless the request names its own, as `@mttp.backend()` has it. Give it to
/// `@mttp.client(backend=...)`.
///
/// `https` origins get HTTP/2 when their server chooses it by ALPN, and
/// HTTP/1.1 on the same connection otherwise; `http` URLs get HTTP/1.1.
/// With no `config`, proxy variables (`http_proxy`, `https_proxy`,
/// `all_proxy`, `no_proxy`) are read from the process environment once, as
/// `@mttp.backend()` reads them, and a scheme with a proxy goes over
/// HTTP/1.1 through it. An explicit `config` is used as it is;
/// `@h1client.ProxyConfig::none()` in it turns proxies off.
/// `max_connection_age_ms` closes connections at that age once their last
/// request ends; zero or less prevents reuse.
///
/// With `http3`, `https` origins are tried over HTTP/3 (QUIC, `@h3client`)
/// first, unless a proxy is configured for them; one whose QUIC handshake
/// does not finish in a second goes over TCP as above, and is not tried
/// over QUIC again for five minutes. The time QUIC took comes off the
/// request's deadline. With `early_data` too, a resumed QUIC connection
/// sends safe requests in 0-RTT (`@h3client.H3Backend::new`).
pub fn backend(
  trust~ : @trust.Trust = System,
  config? : @h1client.ClientConfig,
  max_connection_age_ms? : Int32,
  http3~ : Bool = false,
  early_data~ : Bool = false,
) -> &@mttp_core.Backend {
  let config = config.unwrap_or_else(() => {
    ..@h1client.ClientConfig::default(),
    proxy: @h1client.ProxyConfig::from_env(@env.get_env_var),
  })
  let h2 = @h2client.H2Backend::new(trust~, config~, max_connection_age_ms?)
  if !http3 || config.proxy.https is Some(_) {
    return @codings.Decompress::new(h2)
  }
  @codings.Decompress::new(Http3First::{
    h3: @h3client.H3Backend::new(
      trust~,
      config~,
      max_connection_age_ms?,
      early_data~,
    ),
    h2,
    clock: @runtime.AsyncClock::new(),
  })
}

///|
/// HTTP/3 where the origin speaks it, the TCP backend otherwise.
priv struct Http3First {
  h3 : @h3client.H3Backend
  h2 : @h2client.H2Backend
  clock : &@rt.Clock
}

///|
impl @mttp_core.Backend for Http3First with fn send(self, request, options) {
  let started = self.clock.now_unix_ms()
  match self.h3.try_send(request, options) {
    Some(response) => response
    None => {
      let options = match options.timeout_ms {
        Some(ms) => {
          let left = ms.to_int64() - (self.clock.now_unix_ms() - started)
          {
            ..options,
            timeout_ms: Some(if left < 1L { 1 } else { left.to_int() }),
          }
        }
        None => options
      }
      self.h2.send(request, options)
    }
  }
}

///|
impl @mttp_core.Backend for Http3First with fn close(self) {
  self.h3.close()
  self.h2.close()
}

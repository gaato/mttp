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
pub fn backend(
  trust~ : @trust.Trust = System,
  config? : @h1client.ClientConfig,
  max_connection_age_ms? : Int32,
) -> &@mttp_core.Backend {
  let config = config.unwrap_or_else(() => {
    ..@h1client.ClientConfig::default(),
    proxy: @h1client.ProxyConfig::from_env(@env.get_env_var),
  })
  @codings.Decompress::new(
    @h2client.H2Backend::new(trust~, config~, max_connection_age_ms?),
  )
}

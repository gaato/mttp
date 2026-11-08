///|
fn platform_backend(
  config : @h1client.ClientConfig?,
  trust : @http_async.Trust,
) -> AsyncBackend {
  let config = config.unwrap_or_else(() => {
    ..@h1client.ClientConfig::default(),
    proxy: @h1client.ProxyConfig::from_env(@env.get_env_var),
  })
  let clock = @runtime.AsyncClock::new()
  let client = @h1client.Client::new(
    dialer=@conn.TcpDialer::new(trust~),
    clock~,
    timer=@runtime.ClockTimer::new(clock~),
    coordination=@runtime.RuntimeCoordination::new(),
    config~,
  )
  {
    inner: @codings.Decompress::new(client),
    idle: () => client.idle_connections(),
  }
}

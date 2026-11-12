///|
fn platform_backend(
  config : @h1client.ClientConfig?,
  trust : @trust.Trust,
  clock : &@rt.Clock,
  timer : &@rt.Timer,
) -> AsyncBackend {
  let config = config.unwrap_or_else(() => {
    ..@h1client.ClientConfig::default(),
    proxy: @h1client.ProxyConfig::from_env(@env.get_env_var),
  })
  let client = @h1client.Client::new(
    dialer=@conn.TcpDialer::new(trust~),
    clock~,
    timer~,
    coordination=@runtime.RuntimeCoordination::new(),
    config~,
  )
  {
    inner: @codings.Decompress::new(client),
    idle: () => client.idle_connections(),
  }
}

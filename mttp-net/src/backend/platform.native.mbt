///|
fn platform_backend(settings : Settings) -> AsyncBackend {
  let backend = H1Backend::new(
    proxy?=settings.proxy,
    trust_env=settings.trust_env,
    clock=settings.clock,
    timeout_ms=settings.timeouts.total,
    connect_timeout_ms=settings.timeouts.connect,
    write_timeout_ms=settings.timeouts.write,
    read_timeout_ms=settings.timeouts.read,
    pool_timeout_ms=settings.timeouts.pool,
    max_connections?=settings.max_connections,
    max_connections_per_origin?=settings.max_connections_per_origin,
    max_idle_connections=settings.max_idle_connections,
    max_idle_per_origin=settings.max_idle_per_origin,
    idle_max_ms=settings.idle_max_ms,
    max_body_bytes?=settings.max_body_bytes,
    head_limits=settings.head_limits,
  )
  { inner: backend, idle: () => backend.idle_connections(), }
}

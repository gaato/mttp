///|
/// The settings of a `Client`, fixed at construction. Build them from
/// `ClientConfig::default()` with a record update; the field set is frozen.
///
/// Time limits are in milliseconds and bound one phase each; `None` sets no
/// limit for that phase, so only the per-send `SendOptions.timeout_ms`
/// applies. A nonpositive limit fails its phase at once with `Timeout(ms)`.
///
/// ```mbt check
/// test {
///   let config = {
///     ..@h1client.ClientConfig::default(),
///     connect_timeout_ms: Some(5000),
///     max_connections_per_origin: Some(8),
///   }
///   assert_eq(config.max_idle_per_origin, 4)
///   assert_eq(config.max_body_bytes, None)
/// }
/// ```
#derive(Eq, Debug)
pub(all) struct ClientConfig {
  /// Waiting for a connection slot (phase Pool).
  pool_timeout_ms : Int32?
  /// Opening a connection, TLS included (phase Dial).
  connect_timeout_ms : Int32?
  /// Each write of the request, and each read of a streamed request body
  /// (phase Write).
  write_timeout_ms : Int32?
  /// Waiting for the response head after the request is sent (phase Head),
  /// and each read of the response body (phase Body).
  read_timeout_ms : Int32?
  /// Active exchanges over all origins, or `None` for no cap. A cap below 1
  /// counts as 1. A parked connection holds no slot.
  max_connections : Int32?
  /// Active exchanges per origin, or `None` for no cap; below 1 counts as 1.
  max_connections_per_origin : Int32?
  /// Parked idle connections over all origins; 0 or less disables reuse.
  max_idle_connections : Int32
  /// Parked idle connections per origin; 0 or less disables reuse.
  max_idle_per_origin : Int32
  /// How long a connection may stay parked; 0 or less disables reuse.
  idle_max_ms : Int32
  /// A ceiling on the response body bytes read from the wire (after
  /// transfer framing, before content decoding), in both body modes. With
  /// `Exchange(max_bytes)` the smaller of the two applies; a streamed body
  /// is bounded by this ceiling alone, so `None` lets it run without end.
  max_body_bytes : Int32?
  /// Bounds on the response head, chunk-size lines and trailers.
  head_limits : @h1.Limits
}

///|
/// Compares configurations.
pub extend ClientConfig with Eq::{equal, not_equal}

///|
/// Formats a configuration for diagnostics.
pub extend ClientConfig with @debug.Debug::{to_repr}

///|
/// No phase limits and no connection caps; idle reuse of at most 256
/// connections, 4 per origin, for 10 seconds; no wire ceiling beyond the
/// per-send one; `@h1.Limits::default()` for heads.
pub fn ClientConfig::default() -> ClientConfig {
  {
    pool_timeout_ms: None,
    connect_timeout_ms: None,
    write_timeout_ms: None,
    read_timeout_ms: None,
    max_connections: None,
    max_connections_per_origin: None,
    max_idle_connections: 256,
    max_idle_per_origin: 4,
    idle_max_ms: 10000,
    max_body_bytes: None,
    head_limits: @h1.Limits::default(),
  }
}

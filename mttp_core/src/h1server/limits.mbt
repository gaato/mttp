///|
/// The bounds a server applies to each connection and request. Build them
/// from `ServerLimits::default()` with a record update; `validate` refuses
/// values that would disable a bound.
///
/// ```mbt check
/// test {
///   let limits = { ..@h1server.ServerLimits::default(), max_body_bytes: 4096, }
///   limits.validate()
///   assert_eq(limits.max_header_bytes, 16384)
/// }
/// ```
#derive(Eq, Debug)
pub(all) struct ServerLimits {
  /// Request body bytes after transfer framing; a larger Content-Length is
  /// refused with 413 before the handler runs, and a chunked body fails at
  /// the chunk that crosses it. At least 0.
  max_body_bytes : Int32
  /// Waiting for a request head and reading it, from the end of the
  /// previous exchange (or the start of the connection). At least 1.
  header_timeout_ms : Int32
  /// Reading one request body, from its first pull to its end, each write
  /// of the response, and each read of a streamed response body unless the
  /// response sets `@mttp_core.close_on_shutdown` (an event stream waits for its
  /// next event for any time; shutdown ends it). At least 1.
  body_timeout_ms : Int32
  /// One request head, the start line, empty lines before it and the final
  /// CRLF CRLF included. At least 1.
  max_header_bytes : Int32
  /// Accepted connections the listener adapter may serve at once. The
  /// adapter enforces this across calls to `serve_conn`. At least 1.
  max_connections : Int32
  /// Unread request body bytes the server reads and discards after the
  /// response so the connection can serve the next request; a longer rest
  /// closes the connection instead. At least 0.
  drain_max_bytes : Int32
  /// Running the handler, until it returns the response; `None` sets no
  /// limit. At least 1 when set.
  handler_timeout_ms : Int32?
  /// How long the listener adapter lets running exchanges and background
  /// work finish after a stop before it cancels them. At least 0.
  drain_ms : Int32
}

///|
/// Compares limits field by field.
pub extend ServerLimits with Eq::{equal, not_equal}

///|
/// Formats limits for diagnostics.
pub extend ServerLimits with @debug.Debug::{to_repr}

///|
/// 1 MiB bodies, five-second header and body budgets, 16 KiB heads, 256
/// connections, 64 KiB of unread body drained, no handler deadline and ten
/// seconds to drain at shutdown.
pub fn ServerLimits::default() -> ServerLimits {
  {
    max_body_bytes: 1048576,
    header_timeout_ms: 5000,
    body_timeout_ms: 5000,
    max_header_bytes: 16384,
    max_connections: 256,
    drain_max_bytes: 65536,
    handler_timeout_ms: None,
    drain_ms: 10000,
  }
}

///|
/// Settings refused before any connection is served.
#derive(Debug)
pub(all) suberror ServerConfigError {
  InvalidMaxBodyBytes(value~ : Int32)
  InvalidBodyTimeoutMs(value~ : Int32)
  InvalidHeaderTimeoutMs(value~ : Int32)
  InvalidMaxConnections(value~ : Int32)
  InvalidMaxHeaderBytes(value~ : Int32)
  InvalidDrainMaxBytes(value~ : Int32)
  InvalidHandlerTimeoutMs(value~ : Int32)
  InvalidDrainMs(value~ : Int32)
}

///|
/// Formats the refused setting for diagnostics.
pub extend ServerConfigError with @debug.Debug::{to_repr}

///|
/// Refuses limits that would disable a bound, naming the first invalid
/// field.
pub fn ServerLimits::validate(
  self : ServerLimits,
) -> Unit raise ServerConfigError {
  if self.max_body_bytes < 0 {
    raise InvalidMaxBodyBytes(value=self.max_body_bytes)
  }
  if self.header_timeout_ms <= 0 {
    raise InvalidHeaderTimeoutMs(value=self.header_timeout_ms)
  }
  if self.body_timeout_ms <= 0 {
    raise InvalidBodyTimeoutMs(value=self.body_timeout_ms)
  }
  if self.max_header_bytes < 1 {
    raise InvalidMaxHeaderBytes(value=self.max_header_bytes)
  }
  if self.max_connections < 1 {
    raise InvalidMaxConnections(value=self.max_connections)
  }
  if self.drain_max_bytes < 0 {
    raise InvalidDrainMaxBytes(value=self.drain_max_bytes)
  }
  if self.handler_timeout_ms is Some(value) && value <= 0 {
    raise InvalidHandlerTimeoutMs(value~)
  }
  if self.drain_ms < 0 {
    raise InvalidDrainMs(value=self.drain_ms)
  }
}

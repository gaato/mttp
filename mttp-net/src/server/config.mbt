///|
/// Bounds applied independently to each HTTP/1 connection and request.
pub(all) struct ServerLimits {
  max_body_bytes : Int32
  header_timeout_ms : Int32
  body_timeout_ms : Int32
  max_header_bytes : Int32
  max_connections : Int32
  drain_max_bytes : Int32
  handler_timeout_ms : Int32?
  drain_ms : Int32
}

///|
/// Defaults: 1 MiB bodies, five-second header/body budgets, 16 KiB heads,
/// 256 connections, 64 KiB unread-body draining, no handler deadline and a
/// ten-second graceful shutdown budget.
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
/// Configuration and listening failures, independent of runtime error types.
pub(all) suberror ServerConfigError {
  InvalidMaxBodyBytes(value~ : Int32)
  InvalidBodyTimeoutMs(value~ : Int32)
  InvalidHeaderTimeoutMs(value~ : Int32)
  InvalidMaxConnections(value~ : Int32)
  InvalidMaxHeaderBytes(value~ : Int32)
  InvalidDrainMaxBytes(value~ : Int32)
  InvalidHandlerTimeoutMs(value~ : Int32)
  InvalidDrainMs(value~ : Int32)
  Bind(detail~ : String)
  Accept(detail~ : String)
} derive(Debug)

///|
/// Formats configuration failures.
pub extend ServerConfigError with @debug.Debug::{to_repr}

///|
/// A per-connection failure delivered to the optional error observer.
pub(all) struct ServeError {
  kind : @model.Kind
  phase : @model.Phase
  detail : String
}

///|
fn ServerLimits::validate(self : ServerLimits) -> Unit raise ServerConfigError {
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
  if self.drain_ms < 0 {
    raise InvalidDrainMs(value=self.drain_ms)
  }
  if self.handler_timeout_ms is Some(value) && value <= 0 {
    raise InvalidHandlerTimeoutMs(value~)
  }
}

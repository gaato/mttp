///|
/// Writes the limit that was refused and its value.
pub impl Show for ServerConfigError with fn output(self, logger) {
  let (name, value) = match self {
    InvalidMaxBodyBytes(value~) => ("max_body_bytes", value)
    InvalidBodyTimeoutMs(value~) => ("body_timeout_ms", value)
    InvalidHeaderTimeoutMs(value~) => ("header_timeout_ms", value)
    InvalidMaxConnections(value~) => ("max_connections", value)
    InvalidMaxHeaderBytes(value~) => ("max_header_bytes", value)
    InvalidDrainMaxBytes(value~) => ("drain_max_bytes", value)
    InvalidHandlerTimeoutMs(value~) => ("handler_timeout_ms", value)
    InvalidDrainMs(value~) => ("drain_ms", value)
  }
  logger.write_string("invalid server limit \{name}: \{value}")
}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend ServerConfigError with Show::{output, to_string}

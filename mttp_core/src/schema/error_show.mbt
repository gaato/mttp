///|
/// Writes the decoding failure's message.
pub impl Show for DecodeFailure with fn output(self, logger) {
  logger.write_string(self.message())
}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend DecodeFailure with Show::{output, to_string}

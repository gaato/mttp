///|
/// Writes the failure as `message()` does: its kind, the phase it reached
/// and the detail, such as `Timeout(ms=200) during Head: ...`.
pub impl Show for TransportError with fn output(self, logger) {
  logger.write_string(self.message())
}

///|
/// Writes why the URL was refused.
pub impl Show for UrlError with fn output(self, logger) {
  match self {
    Invalid(reason) => logger.write_string("invalid URL: " + reason)
  }
}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend TransportError with Show::{output, to_string}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend UrlError with Show::{output, to_string}

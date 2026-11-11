///|
/// Writes why the request was refused before anything was sent.
pub impl Show for InvalidRequest with fn output(self, logger) {
  let InvalidRequest(message~) = self
  logger.write_string("invalid request: " + message)
}

///|
/// Writes the status, and for a body that did not decode, why.
pub impl Show for ResponseFailure with fn output(self, logger) {
  match self {
    UnexpectedStatus(head, ..) =>
      logger.write_string("unexpected status \{head.status}")
    Deserialization(head, message~, ..) =>
      logger.write_string(
        "the \{head.status} response did not decode: \{message}",
      )
  }
}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend InvalidRequest with Show::{output, to_string}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend ResponseFailure with Show::{output, to_string}

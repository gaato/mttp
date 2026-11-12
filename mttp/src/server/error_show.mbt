///|
/// Writes which stage of listening failed and why.
pub impl Show for ListenError with fn output(self, logger) {
  match self {
    Config(error) => logger.write_string("server configuration: \{error}")
    Bind(detail~) => logger.write_string("cannot listen: " + detail)
    Accept(detail~) => logger.write_string("accept failed: " + detail)
  }
}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend ListenError with Show::{output, to_string}

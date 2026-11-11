///|
/// Writes each problem as `template: message`, separated by `; `.
pub impl Show for DefinitionError with fn output(self, logger) {
  let DefinitionError(problems) = self
  logger.write_string("endpoint definition problems: ")
  logger.write_string(
    problems.map(p => "\{p.template}: \{p.message}").join("; "),
  )
}

///|
/// Writes each input that failed as `name: message`, separated by `; `.
pub impl Show for InputErrors with fn output(self, logger) {
  let InputErrors(failures) = self
  logger.write_string("invalid input: ")
  logger.write_string(
    failures.map(f => "\{f.atom.name}: \{f.failure.message()}").join("; "),
  )
}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend DefinitionError with Show::{output, to_string}

///|
/// The message, as `\{error}` interpolation writes it.
pub extend InputErrors with Show::{output, to_string}

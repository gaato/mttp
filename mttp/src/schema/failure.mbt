///|
/// A decoding failure category, extensible without changing the error wrapper.
#non_exhaustive
pub(all) enum DecodeKind {
  Missing
  Multiple(Int32)
  Malformed
  Invalid(Array[Issue])
  Mismatch(expected~ : String, actual~ : String)
  TooLarge(limit~ : Int32)
  UnsupportedMediaType(String)
} derive(Debug)

///|
/// An input error with a stable message and structured category.
pub(all) suberror DecodeFailure {
  DecodeFailure(kind~ : DecodeKind, message~ : String)
} derive(Debug)

///|
/// The explanatory message, without formatting the error wrapper.
pub fn DecodeFailure::message(self : DecodeFailure) -> String {
  let DecodeFailure(message~, ..) = self
  message
}

///|
/// Formats the failure category.
pub extend DecodeKind with @debug.Debug::{to_repr}

///|
/// Formats the decoding error.
pub extend DecodeFailure with @debug.Debug::{to_repr}

///|
fn invalid(issues : Array[Issue]) -> DecodeFailure {
  DecodeFailure(
    kind=Invalid(issues),
    message=issues.map(i => i.path + ": " + i.message).join("; "),
  )
}

///|
fn malformed(message : String) -> DecodeFailure {
  DecodeFailure(kind=Malformed, message~)
}

///|
fn pointer_segment(name : String) -> String {
  name.replace_all(old="~", new="~0").replace_all(old="/", new="~1")
}

///|
fn at_path(error : DecodeFailure, path : String) -> DecodeFailure {
  match error {
    DecodeFailure(kind=Invalid(issues), ..) =>
      invalid(issues.map(issue => { ..issue, path: path + issue.path, }))
    _ => error
  }
}

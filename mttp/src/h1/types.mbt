///|
/// Byte limits include terminating CRLFs. Header count excludes the start
/// line and applies independently to heads and trailers.
pub(all) struct Limits {
  max_head_bytes : Int32
  max_chunk_line_bytes : Int32
  max_trailer_bytes : Int32
  max_headers : Int32
} derive(Eq, Debug)

///|
/// Defaults: 16 KiB heads, 4 KiB size lines, 16 KiB trailers, 100 fields.
pub fn Limits::default() -> Limits {
  {
    max_head_bytes: 16384,
    max_chunk_line_bytes: 4096,
    max_trailer_bytes: 16384,
    max_headers: 100,
  }
}

///|
/// Compares parser limits.
pub extend Limits with Eq::{equal, not_equal}

///|
/// Formats parser limits.
pub extend Limits with @debug.Debug::{to_repr}

///|
/// Classification used to choose a response and close a malformed exchange.
#non_exhaustive
pub(all) enum ParseKind {
  HeadTooLarge
  Malformed
  Smuggling
  Unsupported
} derive(Eq, Debug)

///|
/// Compares parser error kinds.
pub extend ParseKind with Eq::{equal, not_equal}

///|
/// Formats parser error kinds.
pub extend ParseKind with @debug.Debug::{to_repr}

///|
/// A codec refusal. Detail is diagnostic text, not a stable machine contract.
pub(all) suberror ParseError {
  ParseError(kind~ : ParseKind, detail~ : String)
} derive(Debug)

///|
/// Formats codec refusals.
pub extend ParseError with @debug.Debug::{to_repr}

///|
/// Supported wire versions.
#non_exhaustive
pub(all) enum Version {
  Http10
  Http11
} derive(Eq, Debug)

///|
/// Compares wire versions.
pub extend Version with Eq::{equal, not_equal}

///|
/// Formats wire versions.
pub extend Version with @debug.Debug::{to_repr}

///|
/// How bytes following a head belong to its message body.
#non_exhaustive
pub(all) enum Framing {
  NoBody
  Length(Int64)
  Chunked
  UntilClose
} derive(Eq, Debug)

///|
/// Compares body framing.
pub extend Framing with Eq::{equal, not_equal}

///|
/// Formats body framing.
pub extend Framing with @debug.Debug::{to_repr}

///|
fn malformed(detail : String) -> ParseError {
  ParseError(kind=Malformed, detail~)
}

///|
fn token(text : String) -> Bool {
  !text.is_empty() &&
  text
  .iter()
  .all(c => {
    match c {
      'a'..<='z' | 'A'..<='Z' | '0'..<='9' => true
      _ => "!#$%&'*+-.^_`|~".contains_char(c)
    }
  })
}

///|
fn latin1(bytes : BytesView) -> String {
  let out = StringBuilder()
  for byte in bytes {
    out.write_char(byte.to_int().unsafe_to_char())
  }
  out.to_string()
}

///|
fn ows(text : String) -> String {
  let mut start = 0
  let mut end = text.length()
  while start < end && (text[start] == ' ' || text[start] == '\t') {
    start += 1
  }
  while end > start && (text[end - 1] == ' ' || text[end - 1] == '\t') {
    end -= 1
  }
  text[start:end].to_owned()
}

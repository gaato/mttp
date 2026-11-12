///|
/// Input bounds of the codec. Byte limits include terminating CRLFs. The
/// field count excludes the start line and applies to a head and, separately,
/// to the trailer section of a chunked body. A negative limit is refused when
/// it is first used.
#derive(Eq, Debug)
pub(all) struct Limits {
  max_head_bytes : Int32
  max_chunk_line_bytes : Int32
  max_trailer_bytes : Int32
  max_headers : Int32
}

///|
/// Defaults: 16 KiB heads, 4 KiB chunk-size lines, 16 KiB trailer sections,
/// 100 fields.
///
/// ```mbt check
/// test {
///   let limits = @h1.Limits::default()
///   assert_eq(limits.max_head_bytes, 16384)
///   let strict = { ..limits, max_headers: 20, }
///   assert_eq(strict.max_headers, 20)
/// }
/// ```
pub fn Limits::default() -> Limits {
  {
    max_head_bytes: 16384,
    max_chunk_line_bytes: 4096,
    max_trailer_bytes: 16384,
    max_headers: 100,
  }
}

///|
/// Compares codec limits.
pub extend Limits with Eq::{equal, not_equal}

///|
/// Formats codec limits.
pub extend Limits with @debug.Debug::{to_repr}

///|
/// Why the codec refused input, which decides the answer and that the
/// connection closes. More kinds may be added; a `match` needs a wildcard.
///
/// - `HeadTooLarge`: a head, a chunk-size line or a trailer section exceeded
///   its byte or field limit (a server answers 431 for a head).
/// - `Malformed`: the bytes are not valid RFC 9112 syntax (400).
/// - `Smuggling`: the framing is ambiguous between implementations, such as
///   Content-Length with Transfer-Encoding (400).
/// - `Unsupported`: valid syntax the codec does not implement, such as a
///   transfer coding other than `chunked` (501) or HTTP/2 (505).
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum ParseKind {
  HeadTooLarge
  Malformed
  Smuggling
  Unsupported
}

///|
/// Compares parse error kinds.
pub extend ParseKind with Eq::{equal, not_equal}

///|
/// Formats parse error kinds.
pub extend ParseKind with @debug.Debug::{to_repr}

///|
/// A codec refusal. `detail` is diagnostic text, not a stable contract;
/// match on `kind`.
#derive(Debug)
pub(all) suberror ParseError {
  ParseError(kind~ : ParseKind, detail~ : String)
}

///|
/// Formats codec refusals.
pub extend ParseError with @debug.Debug::{to_repr}

///|
/// The wire versions the codec reads and writes. A received `HTTP/1.x` with
/// a minor version above 1 is read as `Http11` (RFC 9112, section 2.3).
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum Version {
  Http10
  Http11
}

///|
/// Compares wire versions.
pub extend Version with Eq::{equal, not_equal}

///|
/// Formats wire versions.
pub extend Version with @debug.Debug::{to_repr}

///|
/// How the bytes after a head belong to its message body.
///
/// - `NoBody`: the message has no body; the next bytes start the next
///   message (or, after a successful CONNECT, the tunnel).
/// - `Length(n)`: exactly `n` bytes follow.
/// - `Chunked`: the body is chunked; decode it with `ChunkedDecoder`.
/// - `UntilClose`: the body ends when the peer closes (responses only).
#derive(Eq, Debug)
#non_exhaustive
pub(all) enum Framing {
  NoBody
  Length(Int64)
  Chunked
  UntilClose
}

///|
/// Compares body framing.
pub extend Framing with Eq::{equal, not_equal}

///|
/// Formats body framing.
pub extend Framing with @debug.Debug::{to_repr}

///|
/// A parsed request head. The fields are read-only, so later versions can
/// add fields without breaking callers.
#derive(Eq, Debug)
pub struct ParsedRequest {
  /// The request method.
  meth : @mttp_core.Method
  /// The request target exactly as received: origin-form (`/a?b`),
  /// absolute-form, authority-form (CONNECT) or `*` (OPTIONS).
  target : String
  /// The wire version.
  version : Version
  /// The fields in order, names lowercased, duplicates retained.
  headers : @mttp_core.Headers
}

///|
/// Compares parsed request heads.
pub extend ParsedRequest with Eq::{equal, not_equal}

///|
/// Formats parsed request heads.
pub extend ParsedRequest with @debug.Debug::{to_repr}

///|
/// A parsed response head. The reason phrase is validated and dropped: it
/// carries no information (RFC 9112, section 4).
#derive(Eq, Debug)
pub struct ParsedResponse {
  /// The wire version.
  version : Version
  /// The status code, 100 to 599.
  status : Int32
  /// The fields in order, names lowercased, duplicates retained.
  headers : @mttp_core.Headers
}

///|
/// Compares parsed response heads.
pub extend ParsedResponse with Eq::{equal, not_equal}

///|
/// Formats parsed response heads.
pub extend ParsedResponse with @debug.Debug::{to_repr}

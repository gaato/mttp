///|
priv enum UriPosition {
  Path
  QueryKey
  QueryValue
  Fragment
} derive(Eq)

///|
/// An interpolation builder for URI strings. Literal syntax is preserved;
/// interpolated values are percent-encoded as individual components. Query
/// parameters are staged until their separator so None can omit the whole
/// parameter without retracting or repeatedly copying the preceding URL.
pub struct UriBuilder {
  priv out : StringBuilder
  priv mut param : StringBuilder
  priv mut position : UriPosition
  priv mut query_items : Bool
  priv mut omit : Bool
}

///|
/// Creates an empty URI builder; use uri for interpolation and finalization.
pub fn UriBuilder::new() -> UriBuilder {
  {
    out: StringBuilder(),
    param: StringBuilder(),
    position: Path,
    query_items: false,
    omit: false,
  }
}

///|
fn UriBuilder::commit_param(self : UriBuilder) -> Unit {
  if !self.omit && !self.param.is_empty() {
    self.out.write_char(if self.query_items { '&' } else { '?' })
    self.out.write_string(self.param.to_string())
    self.query_items = true
  }
  self.param = StringBuilder()
  self.omit = false
}

///|
/// Writes URI syntax literally. Reserved characters in interpolated data
/// should instead go through interpolation or write_encoded.
pub fn UriBuilder::write_string(self : UriBuilder, text : String) -> Unit {
  for c in text {
    match (self.position, c) {
      (Path, '?') => self.position = QueryKey
      (QueryKey | QueryValue, '&') => {
        self.commit_param()
        self.position = QueryKey
      }
      (QueryKey | QueryValue, '#') => {
        self.commit_param()
        self.out.write_char(c)
        self.position = Fragment
      }
      (Path, '#') => {
        self.out.write_char(c)
        self.position = Fragment
      }
      (QueryKey, '=') => {
        if !self.omit {
          self.param.write_char(c)
        }
        self.position = QueryValue
      }
      (QueryKey | QueryValue, _) => if !self.omit { self.param.write_char(c) }
      _ => self.out.write_char(c)
    }
  }
}

///|
/// Writes a component, escaping every character outside RFC 3986 unreserved
/// syntax. Even at the start, a plain String cannot inject a scheme or host.
pub fn UriBuilder::write_encoded(self : UriBuilder, value : String) -> Unit {
  let encoded = percent_encode(value)
  match self.position {
    QueryKey | QueryValue => if !self.omit { self.param.write_string(encoded) }
    Path | Fragment => self.out.write_string(encoded)
  }
}

///|
/// Writes an interpolated value using its UriPart implementation.
pub fn[T : UriPart] UriBuilder::write_string_interpolation(
  self : UriBuilder,
  value : T,
) -> Unit {
  value.write_uri(self)
}

///|
/// Returns the current URI without mutating the builder. Empty query syntax
/// and parameters omitted by None do not leave stray separators.
pub fn UriBuilder::to_string(self : UriBuilder) -> String {
  if (self.position == QueryKey || self.position == QueryValue) &&
    !self.omit &&
    !self.param.is_empty() {
    self.out.to_string() +
    (if self.query_items { "&" } else { "?" }) +
    self.param.to_string()
  } else {
    self.out.to_string()
  }
}

///|
/// Types which can contribute URI data. Custom implementations should call
/// write_encoded, or delegate to another UriPart, for untrusted values.
pub(open) trait UriPart {
  fn write_uri(Self, UriBuilder) -> Unit
}

///|
/// Interpolates one encoded string component.
pub impl UriPart for String with fn write_uri(self, builder) {
  builder.write_encoded(self)
}

///|
/// Interpolates one decimal integer component.
pub impl UriPart for Int32 with fn write_uri(self, builder) {
  builder.write_encoded(self.to_string())
}

///|
/// Interpolates one decimal 64-bit integer component.
pub impl UriPart for Int64 with fn write_uri(self, builder) {
  builder.write_encoded(self.to_string())
}

///|
/// Interpolates true or false.
pub impl UriPart for Bool with fn write_uri(self, builder) {
  builder.write_encoded(self.to_string())
}

///|
/// Interpolates the ordinary Double representation as one encoded component.
pub impl UriPart for Double with fn write_uri(self, builder) {
  builder.write_encoded(self.to_string())
}

///|
/// Some delegates; None omits the current query value's entire parameter,
/// or contributes no data outside a query value.
pub impl[T : UriPart] UriPart for T? with fn write_uri(self, builder) {
  match self {
    Some(value) => value.write_uri(builder)
    None =>
      if builder.position == QueryValue {
        builder.omit = true
        builder.param = StringBuilder()
      }
  }
}

///|
/// At an empty query-key position, writes ordered key/value pairs (including
/// duplicates). Elsewhere the form representation is encoded as one component.
pub impl UriPart for Array[(String, String)] with fn write_uri(self, builder) {
  if builder.position != QueryKey || !builder.param.is_empty() {
    builder.write_encoded(form_urlencode(self))
    return
  }
  for i, (key, value) in self {
    if i > 0 {
      builder.write_string("&")
    }
    builder.write_encoded(key)
    builder.write_string("=")
    builder.write_encoded(value)
  }
}

///|
/// Explicit, already-encoded URI syntax. Unlike String interpolation, this
/// may introduce separators, a scheme or an authority; only use trusted data.
pub(all) struct Trusted(String)

///|
/// Writes the trusted text while tracking any URI separators it introduces.
pub impl UriPart for Trusted with fn write_uri(self, builder) {
  builder.write_string(self.0)
}

///|
/// Writes this explicitly trusted fragment to a URI builder.
pub extend Trusted with UriPart::{write_uri}

///|
/// Builds a URI string without parsing it. Send-time validation still applies.
///
/// ```mbt check
/// test {
///   let id = "a/b"
///   let q : String? = None
///   assert_eq(
///     @model.uri(b => b <+ "https://example.test/\{id}?q=\{q}&n=\{3}"),
///     "https://example.test/a%2Fb?n=3",
///   )
/// }
/// ```
pub fn uri(build : (UriBuilder) -> Unit) -> String {
  let builder = UriBuilder::new()
  build(builder)
  builder.to_string()
}

///|
priv enum UriPosition {
  Prefix
  Path
  QueryKey
  QueryValue
  Fragment
} derive(Eq)

///|
/// Architecture: `{ priv buf : StringBuilder; priv mut position : UriPosition }`.
/// A StringBuilder cannot retract the `q=` already written when a `None`
/// arrives, so this keeps a String (private; signature unaffected).
pub struct UriBuilder {
  priv mut out : String
  priv mut position : UriPosition
  priv mut param_start : Int
  priv mut drop_amp : Bool
}

///|
pub fn UriBuilder::new() -> UriBuilder {
  { out: "", position: Prefix, param_start: 0, drop_amp: false }
}

///|
pub fn UriBuilder::write_string(self : UriBuilder, literal : String) -> Unit {
  for c in literal {
    if self.drop_amp {
      self.drop_amp = false
      if c == '&' {
        continue
      }
    }
    match (self.position, c) {
      (Prefix | Path, '?') => {
        self.position = QueryKey
        self.out = self.out + "?"
        self.param_start = self.out.length()
        continue
      }
      (QueryKey | QueryValue, '&') => {
        self.position = QueryKey
        self.out = self.out + "&"
        self.param_start = self.out.length()
        continue
      }
      (QueryKey, '=') => self.position = QueryValue
      (_, '#') => self.position = Fragment
      (Prefix, '/') =>
        if !(self.out.has_suffix("/") || self.out.has_suffix(":")) {
          self.position = Path
        }
      _ => ()
    }
    self.out = self.out + c.to_string()
  }
}

///|
pub fn[T : UriPart] UriBuilder::write_string_interpolation(
  self : UriBuilder,
  value : T,
) -> Unit {
  value.write_uri(self)
}

///|
/// Not in the architecture: user `UriPart` impls for non-delegating types
/// need a way to write an encoded piece.
pub fn UriBuilder::write_encoded(self : UriBuilder, raw : String) -> Unit {
  self.drop_amp = false
  let encoded = match self.position {
    Prefix => raw
    _ => @percent.encode(raw)
  }
  self.out = self.out + encoded
}

///|
fn UriBuilder::write_none(self : UriBuilder) -> Unit {
  if self.position == QueryValue {
    let start = if self.param_start > 0 { self.param_start - 1 } else { 0 }
    let sep = self.out.get_char(start)
    self.out = self.out.view(end_offset=start).to_string()
    if sep is Some('?') {
      self.out = self.out + "?"
      self.param_start = self.out.length()
      self.drop_amp = true
    }
    self.position = QueryKey
  }
}

///|
fn UriBuilder::write_params(self : UriBuilder, params : Array[(String, String)]) -> Unit {
  for i, kv in params {
    if i > 0 {
      self.out = self.out + "&"
    }
    self.out = self.out + @percent.encode(kv.0) + "=" + @percent.encode(kv.1)
  }
}

///|
pub(open) trait UriPart {
  write_uri(Self, UriBuilder) -> Unit
}

///|
pub impl UriPart for String with write_uri(self, b) {
  b.write_encoded(self)
}

///|
pub impl UriPart for Int with write_uri(self, b) {
  b.write_encoded(self.to_string())
}

///|
pub impl UriPart for Int64 with write_uri(self, b) {
  b.write_encoded(self.to_string())
}

///|
pub impl UriPart for Bool with write_uri(self, b) {
  b.write_encoded(self.to_string())
}

///|
pub impl UriPart for Double with write_uri(self, b) {
  b.write_encoded(self.to_string())
}

///|
pub impl[T : UriPart] UriPart for T? with write_uri(self, b) {
  match self {
    Some(v) => v.write_uri(b)
    None => b.write_none()
  }
}

///|
pub impl UriPart for Array[(String, String)] with write_uri(self, b) {
  b.write_params(self)
}

///|
/// An already-encoded piece, written verbatim.
pub(all) struct Trusted(String)

///|
pub impl UriPart for Trusted with write_uri(self, b) {
  b.drop_amp = false
  b.out = b.out + self.0
}

///|
pub fn uri(f : (UriBuilder) -> Unit) -> String {
  let b = UriBuilder::new()
  f(b)
  if b.out.has_suffix("?") {
    b.out.view(end_offset=b.out.length() - 1).to_string()
  } else {
    b.out
  }
}

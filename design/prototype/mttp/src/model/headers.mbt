///|
/// Immutable, ordered, duplicates kept, case-insensitive lookups.
pub struct Headers {
  priv pairs : Array[(String, String)]
} derive(Eq, Debug)

///|
pub fn Headers::empty() -> Headers {
  { pairs: [] }
}

///|
pub fn Headers::of(pairs : ArrayView[(String, String)]) -> Headers {
  { pairs: pairs.to_array() }
}

///|
pub fn Headers::get(self : Headers, name : String) -> String? {
  let n = name.to_lower()
  for p in self.pairs {
    if p.0.to_lower() == n {
      return Some(p.1)
    }
  }
  None
}

///|
pub fn Headers::get_all(self : Headers, name : String) -> Array[String] {
  let n = name.to_lower()
  self.pairs.filter(p => p.0.to_lower() == n).map(p => p.1)
}

///|
pub fn Headers::add(self : Headers, name : String, value : String) -> Headers {
  { pairs: [..self.pairs, (name, value)] }
}

///|
pub fn Headers::remove(self : Headers, name : String) -> Headers {
  let n = name.to_lower()
  { pairs: self.pairs.filter(p => p.0.to_lower() != n) }
}

///|
pub fn Headers::set(self : Headers, name : String, value : String) -> Headers {
  self.remove(name).add(name, value)
}

///|
pub fn Headers::iter(self : Headers) -> Iter[(String, String)] {
  self.pairs.iter()
}

///|
pub fn Headers::length(self : Headers) -> Int {
  self.pairs.length()
}

///|
/// CR/LF/NUL in values, token characters in names.
pub fn Headers::validate(self : Headers) -> Unit raise TransportError {
  for p in self.pairs {
    for c in p.0 {
      if !is_tchar(c) {
        raise TransportError(kind=Invalid, phase=Write, detail="bad header name \{p.0}")
      }
    }
    for c in p.1 {
      if c == '\r' || c == '\n' || c == '\u0000' {
        raise TransportError(kind=Invalid, phase=Write, detail="bad header value for \{p.0}")
      }
    }
  }
}

///|
fn is_tchar(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  "!#$%&'*+-.^_`|~".contains_char(c)
}

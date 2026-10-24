///|
#non_exhaustive
pub(all) enum Phase {
  Pool
  Dial
  Write
  Head
  Body
  Unknown
} derive(Eq, Debug)

///|
#non_exhaustive
pub(all) enum Kind {
  Invalid
  Connect
  Timeout(ms~ : Int)
  Network
  Protocol
  TooLarge(limit~ : Int64)
  Closed
} derive(Eq, Debug)

///|
pub(all) suberror TransportError {
  TransportError(kind~ : Kind, phase~ : Phase, detail~ : String)
} derive(Debug)

///|
pub fn TransportError::is_unsent(self : TransportError) -> Bool {
  let TransportError(phase~, ..) = self
  phase is (Pool | Dial)
}

///|
pub(open) trait BodyStream {
  async fn read_some(Self) -> Bytes? raise TransportError
  fn close(Self) -> Unit
}

///|
pub(all) enum Body {
  Empty
  Bytes(Bytes)
  Stream(&BodyStream, length~ : Int64?)
}

///|
pub(all) enum Method {
  Get
  Head
  Post
  Put
  Delete
  Patch
  Other(String)
} derive(Eq, Debug)

///|
/// Architecture §3.3: `pub struct Url` (read-only outside this package), with a
/// raising parser. Fields mirror gaato/http's Url.
pub struct Url {
  scheme : String?
  host : String?
  path : String
  query : String?
} derive(Eq, Debug)

///|
pub(all) suberror UrlError {
  Invalid(String)
} derive(Debug)

///|
/// A deliberately tiny parser: absolute `scheme://host/path?query` or a
/// relative `/path?query` reference (gaato/http's Url accepts both).
pub fn Url::parse(s : String) -> Url raise UrlError {
  let (scheme, rest) = match s.find("://") {
    Some(i) => (Some(s[:i].to_owned()), s[i + 3:].to_owned())
    None => (None, s)
  }
  let (host, rest) = match scheme {
    None => (None, rest)
    Some(_) =>
      match rest.find("/") {
        Some(i) => (Some(rest[:i].to_owned()), rest[i:].to_owned())
        None => (Some(rest), "/")
      }
  }
  if host is Some("") {
    raise Invalid("empty host")
  }
  guard rest.has_prefix("/") else { raise Invalid("not a path: " + rest) }
  match rest.find("?") {
    Some(i) =>
      { scheme, host, path: rest[:i].to_owned(), query: Some(rest[i + 1:].to_owned()) }
    None => { scheme, host, path: rest, query: None }
  }
}

///|
pub fn Url::to_string(self : Url) -> String {
  let base = match (self.scheme, self.host) {
    (Some(s), Some(h)) => s + "://" + h
    _ => ""
  }
  match self.query {
    Some(q) => base + self.path + "?" + q
    None => base + self.path
  }
}

///|
/// Prototype join used by PartialRequest::base_url: sdk-runtime prefix-join
/// semantics. gaato/http's real Url::resolve is RFC 3986 (see ../urlres).
pub fn Url::resolve(self : Url, reference : Url) -> Url {
  match reference.scheme {
    Some(_) => reference
    None => {
      // sdk-runtime's prefix join (NOT RFC 3986): keep the base path.
      let base = if self.path.has_suffix("/") {
        self.path[:self.path.length() - 1].to_owned()
      } else {
        self.path
      }
      { ..reference, scheme: self.scheme, host: self.host, path: base + reference.path }
    }
  }
}

///|
pub struct AttributeKey[T] {
  priv id : Int
  priv slot : Ref[T?]
}

///|
let next_key : Ref[Int] = { val: 0 }

///|
pub fn[T] AttributeKey::new() -> AttributeKey[T] {
  next_key.val += 1
  { id: next_key.val, slot: { val: None } }
}

///|
pub struct Attributes {
  priv entries : Map[Int, () -> Unit]
}

///|
pub fn Attributes::empty() -> Attributes {
  { entries: Map([]) }
}

///|
pub fn[T] Attributes::put(
  self : Attributes,
  k : AttributeKey[T],
  v : T,
) -> Attributes {
  let m = self.entries.copy()
  m[k.id] = () => k.slot.val = Some(v)
  { entries: m }
}

///|
pub fn[T] Attributes::get(self : Attributes, k : AttributeKey[T]) -> T? {
  match self.entries.get(k.id) {
    Some(f) => {
      f()
      let v = k.slot.val
      k.slot.val = None
      v
    }
    None => None
  }
}

///|
/// Immutable headers (architecture §3.3); `get` is case-insensitive.
pub(all) struct Headers(Array[(String, String)]) derive(Debug)

///|
pub fn Headers::get(self : Headers, name : String) -> String? {
  let Headers(pairs) = self
  for p in pairs {
    if p.0.to_lower() == name.to_lower() {
      return Some(p.1)
    }
  }
  None
}

///|
pub fn Headers::add(self : Headers, name : String, value : String) -> Headers {
  let Headers(pairs) = self
  Headers([..pairs, (name, value)])
}

///|
pub fn Headers::remove(self : Headers, name : String) -> Headers {
  let Headers(pairs) = self
  Headers(pairs.filter(p => p.0.to_lower() != name.to_lower()))
}

///|
pub(all) struct Request {
  meth : Method
  url : Url
  headers : Headers
  body : Body
  attributes : Attributes
}

///|
pub fn Request::new(meth : Method, url : Url) -> Request {
  { meth, url, headers: Headers([]), body: Empty, attributes: Attributes::empty() }
}

///|
pub(all) struct ResponseHead {
  status : Int
  headers : Headers
} derive(Debug)

///|
pub(all) struct Response {
  status : Int
  headers : Headers
  body : Body
}

///|
pub fn Response::head(self : Response) -> ResponseHead {
  { status: self.status, headers: self.headers }
}

///|
pub fn Response::close(self : Response) -> Unit {
  if self.body is Stream(s, ..) {
    s.close()
  }
}

///|
pub fn parse_link_next(headers : Headers) -> String? {
  guard headers.get("link") is Some(link) else { return None }
  for part in link.split(",") {
    let part = part.trim().to_owned()
    if part.contains("rel=\"next\"") {
      guard part.find(">") is Some(end) else { continue }
      return Some(part[1:end].to_owned())
    }
  }
  None
}

///|
pub(open) trait Clock {
  async fn sleep(Self, Int) -> Unit noraise
  fn now_unix_ms(Self) -> Int64
}

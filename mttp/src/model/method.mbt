///|
/// Standard HTTP methods and extension tokens.
#non_exhaustive
pub(all) enum Method {
  Get
  Head
  Post
  Put
  Delete
  Connect
  Options
  Trace
  Patch
  Other(String)
} derive(Eq, Hash, Debug)

///|
/// Parses a case-sensitive method token, retaining unknown tokens verbatim.
pub fn Method::parse(s : String) -> Method {
  match s {
    "GET" => Get
    "HEAD" => Head
    "POST" => Post
    "PUT" => Put
    "DELETE" => Delete
    "CONNECT" => Connect
    "OPTIONS" => Options
    "TRACE" => Trace
    "PATCH" => Patch
    other => Other(other)
  }
}

///|
/// Returns the wire method token.
pub fn Method::to_string(self : Method) -> String {
  match self {
    Get => "GET"
    Head => "HEAD"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Connect => "CONNECT"
    Options => "OPTIONS"
    Trace => "TRACE"
    Patch => "PATCH"
    Other(s) => s
  }
}

///|
/// Reports methods defined as idempotent by HTTP semantics.
pub fn Method::is_idempotent(self : Method) -> Bool {
  self is (Get | Head | Put | Delete | Options | Trace)
}

///|
/// Writes the wire method token.
pub impl Show for Method with fn output(self, logger) {
  logger.write_string(self.to_string())
}

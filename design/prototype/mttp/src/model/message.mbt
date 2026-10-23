///|
/// `url` is the request target as given: an absolute URL or a relative
/// reference ("/users/1?x=2"). Backends parse it once at send time
/// (Kind::Invalid, phase Pool, so it is unsent); `Client` joins a relative
/// target onto its base URL by prefix (sdk-runtime semantics, not RFC 3986).
pub(all) struct Request {
  meth : Method
  url : String
  headers : Headers
  body : Body
  attributes : Attributes
}

///|
pub fn Request::new(meth : Method, url : String) -> Request {
  { meth, url, headers: Headers::empty(), body: Empty, attributes: Attributes::empty() }
}

///|
pub fn Request::get(url : String) -> Request {
  Request::new(Get, url)
}

///|
pub fn Request::post(url : String) -> Request {
  Request::new(Post, url)
}

///|
pub fn Request::put(url : String) -> Request {
  Request::new(Put, url)
}

///|
pub fn Request::delete(url : String) -> Request {
  Request::new(Delete, url)
}

///|
pub fn Request::header(self : Request, name : String, value : String) -> Request {
  { ..self, headers: self.headers.add(name, value) }
}

///|
pub fn Request::set_header(self : Request, name : String, value : String) -> Request {
  { ..self, headers: self.headers.set(name, value) }
}

///|
pub fn Request::bearer(self : Request, token : String) -> Request {
  self.set_header("authorization", "Bearer \{token}")
}

///|
pub fn Request::query(self : Request, name : String, value : String) -> Request {
  { ..self, url: append_query(self.url, name, value) }
}

///|
pub fn Request::body_bytes(
  self : Request,
  b : Bytes,
  content_type? : String = "application/octet-stream",
) -> Request {
  { ..self, headers: self.headers.set("content-type", content_type), body: Bytes(b) }
}

///|
pub fn Request::body_text(self : Request, s : String) -> Request {
  self.body_bytes(@utf8.encode(s), content_type="text/plain; charset=utf-8")
}

///|
pub fn Request::body_json(self : Request, j : Json) -> Request {
  self.body_bytes(@utf8.encode(j.stringify()), content_type="application/json")
}

///|
pub fn Request::body_stream(
  self : Request,
  s : &BodyStream,
  length? : Int64,
  content_type? : String = "application/octet-stream",
) -> Request {
  { ..self, headers: self.headers.set("content-type", content_type), body: Stream(s, length~) }
}

///|
pub fn[T] Request::attribute(self : Request, key : AttributeKey[T], value : T) -> Request {
  { ..self, attributes: self.attributes.put(key, value) }
}

///|
pub(all) struct RequestHead {
  meth : Method
  url : String
  headers : Headers
} derive(Eq, Debug)

///|
pub fn Request::head(self : Request) -> RequestHead {
  { meth: self.meth, url: self.url, headers: self.headers }
}

///|
pub(all) struct ResponseHead {
  status : Int
  headers : Headers
} derive(Eq, Debug)

///|
/// One response type for both directions. A server closes the connection
/// after a response carrying `Connection: close` (413 does). `attributes`
/// is the response-side channel: FollowRedirects records the final URL and
/// history there, and the router records the matched route template.
pub(all) struct Response {
  status : Int
  headers : Headers
  body : Body
  attributes : Attributes
}

///|
pub fn Response::new(status : Int, headers? : Headers = Headers::empty(), body? : Body = Empty) -> Response {
  { status, headers, body, attributes: Attributes::empty() }
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
pub fn Response::closes_connection(self : Response) -> Bool {
  self.headers.get("connection").map(v => v.to_lower() == "close").unwrap_or(false)
}

///|
/// A server-side handler. Adapters (mttp-net serve, fetch_handler) and
/// the Router all speak this type. WebSocket Upgrade is not in v0.x; a later
/// 101 response can carry the upgrade callback in an attribute.
pub type Handler = async (Request) -> Response noraise

///|
pub fn is_success(status : Int) -> Bool {
  status >= 200 && status < 300
}

///|
pub fn reason_phrase(status : Int) -> String {
  match status {
    200 => "OK"
    201 => "Created"
    204 => "No Content"
    400 => "Bad Request"
    401 => "Unauthorized"
    403 => "Forbidden"
    404 => "Not Found"
    405 => "Method Not Allowed"
    406 => "Not Acceptable"
    413 => "Content Too Large"
    415 => "Unsupported Media Type"
    422 => "Unprocessable Content"
    431 => "Request Header Fields Too Large"
    500 => "Internal Server Error"
    _ => ""
  }
}

///|
pub fn percent_decode(s : String) -> String raise UrlError {
  @percent.decode(s) catch {
    _ => raise UrlError::Invalid("bad percent-encoding: \{s}")
  }
}

///|
/// Decoded path segments, for routing.
pub fn Url::path_segments(self : Url) -> Array[String] raise UrlError {
  let p = self.path
  if p == "" || p == "/" {
    return []
  }
  let start = if p.has_prefix("/") { 1 } else { 0 }
  let out = []
  for seg in p.view(start_offset=start).split("/") {
    out.push(percent_decode(seg.to_string()))
  }
  out
}

///|
/// Base-URL join by prefix (sdk-runtime's `base_url` semantics): an
/// absolute http(s) target passes through; otherwise one slash is kept
/// between base and target. "https://api.openai.com/v1" + "/chat" gives
/// "https://api.openai.com/v1/chat" (RFC 3986 `resolve` would drop /v1).
pub fn join_url(base : String, target : String) -> String {
  if base == "" || target.has_prefix("http://") || target.has_prefix("https://") {
    return target
  }
  let b = if base.has_suffix("/") { base.view(end_offset=base.length() - 1).to_string() } else { base }
  if target == "" {
    b
  } else if target.has_prefix("/") || target.has_prefix("?") {
    b + target
  } else {
    b + "/" + target
  }
}

///|
/// Encodes path segments for a request target ("/users/a%2Fb").
pub fn encode_path(segments : Array[String]) -> String {
  let b = StringBuilder()
  for s in segments {
    b.write_char('/')
    b.write_string(@percent.encode(s))
  }
  let p = b.to_string()
  if p == "" { "/" } else { p }
}

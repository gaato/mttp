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
/// Creates a request with empty headers, attributes and body.
pub fn Request::new(meth : Method, url : String) -> Request {
  {
    meth,
    url,
    headers: Headers::empty(),
    body: Empty,
    attributes: Attributes::empty(),
  }
}

///|
/// Creates a GET request.
pub fn Request::get(url : String) -> Request {
  Request::new(Get, url)
}

///|
/// Creates a POST request.
pub fn Request::post(url : String) -> Request {
  Request::new(Post, url)
}

///|
/// Creates a PUT request.
pub fn Request::put(url : String) -> Request {
  Request::new(Put, url)
}

///|
/// Creates a PATCH request.
pub fn Request::patch(url : String) -> Request {
  Request::new(Patch, url)
}

///|
/// Creates an OPTIONS request.
pub fn Request::options(url : String) -> Request {
  Request::new(Options, url)
}

///|
/// Creates a DELETE request.
pub fn Request::delete(url : String) -> Request {
  Request::new(Delete, url)
}

///|
/// Returns a copy with an additional header, preserving duplicate fields.
pub fn Request::header(
  self : Request,
  name : String,
  value : String,
) -> Request {
  { ..self, headers: self.headers.add(name, value), }
}

///|
/// Returns a copy replacing every header of this name at its first position.
pub fn Request::set_header(
  self : Request,
  name : String,
  value : String,
) -> Request {
  { ..self, headers: self.headers.set(name, value), }
}

///|
/// Sets a bearer Authorization header on a copy.
pub fn Request::bearer(self : Request, token : String) -> Request {
  self.set_header("authorization", "Bearer \{token}")
}

///|
/// Sets Basic authorization from UTF-8 username and password bytes. A colon
/// separates the username from the password; it cannot be part of a username.
pub fn Request::basic(
  self : Request,
  username : String,
  password : String,
) -> Request {
  self.set_header(
    "authorization",
    "Basic " + @base64.encode(encode_utf8(username + ":" + password)),
  )
}

///|
/// Appends a percent-encoded query parameter to a copy.
pub fn Request::query(self : Request, name : String, value : String) -> Request {
  { ..self, url: append_query(self.url, name, value), }
}

///|
/// Sets a replayable body on a copy, optionally replacing its content type.
pub fn Request::body_bytes(
  self : Request,
  b : Bytes,
  content_type? : String,
) -> Request {
  {
    ..self,
    headers: match content_type {
      Some(value) => self.headers.set("content-type", value)
      None => self.headers
    },
    body: Bytes(b),
  }
}

///|
/// Sets a UTF-8 text body, replacing unpaired surrogates with U+FFFD.
pub fn Request::body_text(self : Request, s : String) -> Request {
  self.body_bytes(encode_utf8(s), content_type="text/plain; charset=utf-8")
}

///|
/// Serializes JSON as UTF-8 with the application/json content type.
pub fn Request::body_json(self : Request, j : Json) -> Request {
  self.body_bytes(encode_utf8(j.stringify()), content_type="application/json")
}

///|
/// Sets a stream that can be acquired once, optionally enforcing its length.
pub fn Request::body_stream(
  self : Request,
  s : &BodyStream,
  length? : Int64,
  content_type~ : String = "application/octet-stream",
) -> Request {
  {
    ..self,
    headers: self.headers.set("content-type", content_type),
    body: Stream(StreamBody::new(s, length?)),
  }
}

///|
/// Associates typed local metadata with a copy; it is never sent as a header.
pub fn[T] Request::attribute(
  self : Request,
  key : AttributeKey[T],
  value : T,
) -> Request {
  { ..self, attributes: self.attributes.put(key, value), }
}

///|
/// Request metadata without its body or local attributes.
pub(all) struct RequestHead {
  meth : Method
  url : String
  headers : Headers
} derive(Eq, Debug)

///|
/// Extracts request metadata.
pub fn Request::head(self : Request) -> RequestHead {
  { meth: self.meth, url: self.url, headers: self.headers, }
}

///|
/// Response status and headers without the body.
pub(all) struct ResponseHead {
  status : Int32
  headers : Headers
} derive(Eq, Debug)

///|
/// One response type for both directions. A server closes the connection
/// after a response carrying `Connection: close` (413 does). `attributes`
/// is the response-side channel: FollowRedirects records the final URL and
/// history there, and the router records the matched route template.
pub(all) struct Response {
  status : Int32
  headers : Headers
  body : Body
  attributes : Attributes
}

///|
/// Creates a response, defaulting to empty headers and body.
pub fn Response::new(
  status : Int32,
  headers~ : Headers = Headers::empty(),
  body~ : Body = Empty,
) -> Response {
  { status, headers, body, attributes: Attributes::empty(), }
}

///|
/// Extracts response metadata.
pub fn Response::head(self : Response) -> ResponseHead {
  { status: self.status, headers: self.headers, }
}

///|
/// Releases a streaming response body; empty and byte bodies need no cleanup.
pub fn Response::close(self : Response) -> Unit {
  if self.body is Stream(s) {
    s.close()
  }
}

///|
/// Reports a close token across all Connection header values.
pub fn Response::closes_connection(self : Response) -> Bool {
  self.headers
  .get_all("connection")
  .iter()
  .any(value => {
    value.split(",").any(token => token.trim().to_owned().to_lower() == "close")
  })
}

///|
/// A server-side handler. Adapters (mttp-net serve, fetch_handler) and
/// the Router all speak this type. WebSocket Upgrade is not in v0.x; a later
/// 101 response can carry the upgrade callback in an attribute.
pub type Handler = async (Request) -> Response noraise

///|
/// Reports whether a status belongs to the successful 2xx class.
pub fn is_success(status : Int32) -> Bool {
  status >= 200 && status < 300
}

///|
/// Returns a conventional phrase for common statuses, or an empty string.
pub fn reason_phrase(status : Int32) -> String {
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
/// Decodes percent-encoded UTF-8, refusing malformed escapes or encoding.
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
    out.push(percent_decode(seg.to_owned()))
  }
  out
}

///|
/// Base-URL join by prefix (sdk-runtime's `base_url` semantics): an
/// absolute http(s) target passes through; otherwise one slash is kept
/// between base and target. "https://api.openai.com/v1" + "/chat" gives
/// "https://api.openai.com/v1/chat" (RFC 3986 `resolve` would drop /v1).
pub fn join_url(base : String, target : String) -> String {
  let prefix = target[:8].to_owned().to_lower()
  if base == "" || prefix.has_prefix("http://") || prefix.has_prefix("https://") {
    return target
  }
  let b = if base.has_suffix("/") {
    base.view(end_offset=base.length() - 1).to_owned()
  } else {
    base
  }
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
  if p == "" {
    "/"
  } else {
    p
  }
}

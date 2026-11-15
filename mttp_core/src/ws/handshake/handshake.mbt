///|
let websocket_guid : String = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

///|
fn handshake(status : Int32, detail : String) -> @ws.WsError {
  @ws.WsError(kind=Handshake(status~), detail~)
}

///|
fn refuse(
  status : Int32,
  detail : String,
  headers~ : @mttp_core.Headers = @mttp_core.Headers::empty(),
) -> Refusal {
  Refusal(status~, headers~, detail~)
}

///|
/// Creates the RFC 6455 nonce from exactly 16 injected random bytes.
pub fn new_key(entropy : (Int32) -> Bytes?) -> String raise @ws.WsError {
  guard entropy(16) is Some(bytes) else {
    raise handshake(500, "entropy source returned no WebSocket key")
  }
  if bytes.length() != 16 {
    raise handshake(
      500, "entropy source returned a WebSocket key of wrong length",
    )
  }
  @base64.encode(bytes)
}

///|
/// Computes Sec-WebSocket-Accept from the textual nonce and RFC GUID.
pub fn accept_value(key : String) -> String {
  @base64.encode(@sha1.digest(@utf8.encode(key + websocket_guid)))
}

///|
fn list_tokens(headers : @mttp_core.Headers, name : String) -> Array[String] {
  let tokens = []
  for value in headers.get_all(name) {
    for token in value.split(",") {
      tokens.push(token.trim(chars=" \t").to_owned())
    }
  }
  tokens
}

///|
fn contains_token(
  headers : @mttp_core.Headers,
  name : String,
  wanted : String,
) -> Bool {
  list_tokens(headers, name).any(token => token.to_lower() == wanted)
}

///|
fn validate_tokens(
  values : Array[String],
  what : String,
) -> Unit raise @ws.WsError {
  let seen : Map[String, Unit] = Map([])
  for value in values {
    if value.is_empty() || !value.iter().all(token_char) {
      raise handshake(400, "invalid \{what} token")
    }
    if seen.contains(value) {
      raise handshake(400, "duplicate \{what} token")
    }
    seen[value] = ()
  }
}

///|
fn parse_offered_extensions(
  values : Array[String],
) -> Array[Extension] raise @ws.WsError {
  if values.is_empty() {
    return []
  }
  parse_extensions(values.join(", "))
}

///|
fn key_bytes(key : String) -> Bytes? {
  try @base64.decode(key, ignore_whitespace=false) catch {
    _ => None
  } noraise {
    bytes => Some(bytes)
  }
}

///|
fn request_parts(url : String) -> (String, String, String) raise @ws.WsError {
  if url.contains("#") {
    raise handshake(400, "WebSocket URL contains a fragment")
  }
  let normalized = @mttp_core.Url::parse(url).to_string() catch {
    _ => raise handshake(400, "invalid WebSocket URL")
  }
  let (http_scheme, start) = if normalized.has_prefix("ws://") {
    ("http", 5)
  } else if normalized.has_prefix("wss://") {
    ("https", 6)
  } else {
    raise handshake(400, "WebSocket URL scheme must be ws or wss")
  }
  let rest = normalized[start:]
  let cut = match rest.find_by(c => c == '/' || c == '?') {
    Some(i) => i
    None => rest.length()
  }
  let authority = rest[:cut].to_owned()
  if authority.is_empty() || authority.contains("@") {
    raise handshake(400, "WebSocket URL must have a host and no userinfo")
  }
  let suffix = rest[cut:].to_owned()
  let target = if suffix.is_empty() {
    "/"
  } else if suffix.has_prefix("?") {
    "/" + suffix
  } else {
    suffix
  }
  (http_scheme + "://" + authority + target, authority, target)
}

///|
/// Builds a validated HTTP Upgrade request from a ws or wss URL.
pub fn client_request(
  url : String,
  key~ : String,
  subprotocols? : Array[String],
  extensions? : Array[String],
  origin? : String,
  headers? : @mttp_core.Headers,
) -> @mttp_core.Request raise @ws.WsError {
  let protocols = subprotocols.unwrap_or([])
  validate_tokens(protocols, "subprotocol")
  let parsed_extensions = parse_offered_extensions(extensions.unwrap_or([]))
  guard key_bytes(key) is Some(bytes) && bytes.length() == 16 else {
    raise handshake(400, "Sec-WebSocket-Key must encode 16 bytes")
  }
  let (http_url, host, _) = request_parts(url)
  let caller = headers.unwrap_or(@mttp_core.Headers::empty())
  for
    name in [
      "host", "upgrade", "connection", "sec-websocket-key", "sec-websocket-version",
      "sec-websocket-protocol", "sec-websocket-extensions", "origin",
    ] {
    if caller.contains(name) {
      raise handshake(400, "caller header overrides WebSocket handshake field")
    }
  }
  let mut all = caller
  all = all.add("host", host)
  all = all.add("upgrade", "websocket")
  all = all.add("connection", "Upgrade")
  all = all.add("sec-websocket-key", key)
  all = all.add("sec-websocket-version", "13")
  if !protocols.is_empty() {
    all = all.add("sec-websocket-protocol", protocols.join(", "))
  }
  if !parsed_extensions.is_empty() {
    all = all.add(
      "sec-websocket-extensions",
      print_extensions(parsed_extensions),
    )
  }
  if origin is Some(value) {
    all = all.add("origin", value)
  }
  let request = { ..@mttp_core.Request::get(http_url), headers: all, }
  request.validate() catch {
    _ => raise handshake(400, "invalid HTTP handshake request")
  }
  request
}

///|
fn one_header(
  headers : @mttp_core.Headers,
  name : String,
) -> String? raise @ws.WsError {
  match headers.get_all(name) {
    [] => None
    [value] => Some(value)
    _ => raise handshake(400, "duplicate \{name} field")
  }
}

///|
fn extension_subset(
  selected : Array[Extension],
  offered : Array[Extension],
) -> Bool {
  let remaining : Map[String, Int32] = Map([])
  for extension in offered {
    remaining[extension.name] = remaining.get(extension.name).unwrap_or(0) + 1
  }
  for extension in selected {
    let count = remaining.get(extension.name).unwrap_or(0)
    if count == 0 {
      return false
    }
    remaining[extension.name] = count - 1
  }
  true
}

///|
/// Validates a 101 response against exactly what the client offered.
pub fn check_server_response(
  response : @mttp_core.Response,
  key~ : String,
  offered_subprotocols~ : Array[String],
  offered_extensions~ : Array[String],
) -> Accepted raise @ws.WsError {
  if response.status != 101 {
    raise handshake(response.status, "server did not switch protocols")
  }
  if !contains_token(response.headers, "upgrade", "websocket") {
    raise handshake(101, "Upgrade does not contain websocket")
  }
  if !contains_token(response.headers, "connection", "upgrade") {
    raise handshake(101, "Connection does not contain Upgrade")
  }
  let accept = one_header(response.headers, "sec-websocket-accept") catch {
    @ws.WsError(detail~, ..) => raise handshake(101, detail)
  }
  if accept != Some(accept_value(key)) {
    raise handshake(101, "Sec-WebSocket-Accept does not match")
  }
  validate_tokens(offered_subprotocols, "subprotocol")
  let protocol_values = list_tokens(response.headers, "sec-websocket-protocol")
  if protocol_values.length() > 1 ||
    response.headers.get_all("sec-websocket-protocol").length() > 1 {
    raise handshake(101, "server returned more than one subprotocol")
  }
  let subprotocol = protocol_values.get(0)
  if subprotocol is Some(value) && !offered_subprotocols.contains(value) {
    raise handshake(101, "server returned an unoffered subprotocol")
  }
  let extension_fields = response.headers.get_all("sec-websocket-extensions")
  if extension_fields.length() > 1 {
    raise handshake(101, "server returned multiple extension fields")
  }
  let selected = parse_offered_extensions(extension_fields) catch {
    @ws.WsError(detail~, ..) => raise handshake(101, detail)
  }
  let offered = parse_offered_extensions(offered_extensions)
  if !extension_subset(selected, offered) {
    raise handshake(101, "server returned an unoffered extension")
  }
  { subprotocol, extensions: selected, }
}

///|
fn refusal_from_ws(error : @ws.WsError, status : Int32) -> Refusal {
  let @ws.WsError(detail~, ..) = error
  refuse(status, detail)
}

///|
fn request_origin(request : @mttp_core.Request) -> @mttp_core.Url raise Refusal {
  @mttp_core.Url::parse(request.url) catch {
    _ => raise refuse(400, "request URL has no valid origin")
  }
}

///|
fn check_origin(
  request : @mttp_core.Request,
  policy : OriginPolicy,
) -> Unit raise Refusal {
  let fields = request.headers.get_all("origin")
  if fields.is_empty() {
    return
  }
  if fields.length() != 1 {
    raise refuse(400, "multiple Origin fields")
  }
  let origin = @mttp_core.Url::parse(fields[0]) catch {
    _ => raise refuse(403, "invalid Origin")
  }
  let allowed = match policy {
    SameOrigin => origin.same_origin(request_origin(request))
    Allow(origins) =>
      origins.any(candidate => {
        try @mttp_core.Url::parse(candidate) catch {
          _ => false
        } noraise {
          parsed => origin.same_origin(parsed)
        }
      })
    Any => true
  }
  if !allowed {
    raise refuse(403, "Origin is not allowed")
  }
}

///|
fn require_one(
  headers : @mttp_core.Headers,
  name : String,
) -> String raise Refusal {
  match headers.get_all(name) {
    [value] => value
    [] => raise refuse(400, "missing \{name} field")
    _ => raise refuse(400, "multiple \{name} fields")
  }
}

///|
fn request_has_body(request : @mttp_core.Request) -> Bool raise Refusal {
  if request.headers.contains("transfer-encoding") {
    return true
  }
  for value in request.headers.get_all("content-length") {
    let length = @string.parse_int64(value) catch {
      _ => raise refuse(400, "invalid Content-Length")
    }
    if length < 0L {
      raise refuse(400, "invalid Content-Length")
    }
    if length > 0L {
      return true
    }
  }
  match request.body.length() {
    Some(length) => length > 0L
    None => true
  }
}

///|
/// Validates an HTTP/1.1 WebSocket Upgrade request without performing I/O.
pub fn check_client_request(
  request : @mttp_core.Request,
  origins~ : OriginPolicy = SameOrigin,
  subprotocols? : Array[String],
  extensions? : Array[String],
) -> Offer raise Refusal {
  request.validate() catch {
    _ => raise refuse(400, "invalid HTTP handshake request")
  }
  if request.meth != Get {
    raise refuse(400, "WebSocket handshake method is not GET")
  }
  let host = require_one(request.headers, "host")
  if host.is_empty() {
    raise refuse(400, "empty Host field")
  }
  if !contains_token(request.headers, "upgrade", "websocket") {
    raise refuse(400, "Upgrade does not contain websocket")
  }
  if !contains_token(request.headers, "connection", "upgrade") {
    raise refuse(400, "Connection does not contain Upgrade")
  }
  let versions = request.headers.get_all("sec-websocket-version")
  if versions.length() != 1 || versions[0].trim(chars=" \t") != "13" {
    raise refuse(
      426,
      "Sec-WebSocket-Version is not 13",
      headers=@mttp_core.Headers::of([("sec-websocket-version", "13")]),
    )
  }
  let key = require_one(request.headers, "sec-websocket-key")
  guard key_bytes(key) is Some(decoded) else {
    raise refuse(400, "Sec-WebSocket-Key is not base64")
  }
  if decoded.length() != 16 {
    raise refuse(400, "Sec-WebSocket-Key does not decode to 16 bytes")
  }
  if request_has_body(request) {
    raise refuse(400, "WebSocket handshake request has a body")
  }
  check_origin(request, origins)
  let client_protocols = list_tokens(request.headers, "sec-websocket-protocol")
  validate_tokens(client_protocols, "subprotocol") catch {
    error => raise refusal_from_ws(error, 400)
  }
  let client_extensions = parse_offered_extensions(
    request.headers.get_all("sec-websocket-extensions"),
  ) catch {
    error => raise refusal_from_ws(error, 400)
  }
  let supported_protocols = subprotocols.unwrap_or([])
  validate_tokens(supported_protocols, "subprotocol") catch {
    error => raise refusal_from_ws(error, 500)
  }
  let supported_extensions = parse_offered_extensions(extensions.unwrap_or([])) catch {
    error => raise refusal_from_ws(error, 500)
  }
  {
    key,
    subprotocols: client_protocols,
    extensions: client_extensions,
    supported_subprotocols: supported_protocols,
    supported_extensions,
  }
}

///|
/// Builds the value-only 101 response after checking the server's selection.
pub fn Offer::accept(
  self : Offer,
  subprotocol? : String,
  extensions? : Array[Extension],
) -> @mttp_core.Response raise @ws.WsError {
  if subprotocol is Some(value) &&
    (
      !self.subprotocols.contains(value) ||
      !self.supported_subprotocols.contains(value)
    ) {
    raise handshake(500, "selected subprotocol was not offered and supported")
  }
  let selected = extensions.unwrap_or([])
  if !extension_subset(selected, self.extensions) ||
    !extension_subset(selected, self.supported_extensions) {
    raise handshake(500, "selected extension was not offered and supported")
  }
  let mut headers = @mttp_core.Headers::of([
    ("upgrade", "websocket"),
    ("connection", "Upgrade"),
    ("sec-websocket-accept", accept_value(self.key)),
  ])
  if subprotocol is Some(value) {
    headers = headers.add("sec-websocket-protocol", value)
  }
  if !selected.is_empty() {
    headers = headers.add(
      "sec-websocket-extensions",
      print_extensions(selected),
    )
  }
  @mttp_core.Response::new(101, headers~)
}

// From a Request to the header fields of HTTP/2 and HTTP/3, and from response
// fields back: the two forbid the same fields (RFC 9113, section 8.2.2;
// RFC 9114, section 4.2), and nghttp2 and nghttp3 refuse the same
// malformed heads.

///|
/// `error` with its phase replaced.
pub fn with_phase(
  error : @mttp_core.TransportError,
  phase : @mttp_core.Phase,
) -> @mttp_core.TransportError {
  let @mttp_core.TransportError(kind~, detail~, ..) = error
  @mttp_core.TransportError(kind~, phase~, detail~)
}

///|
/// `Invalid` in phase Pool, unsent.
pub fn invalid(detail : String) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Invalid, phase=Pool, detail~)
}

///|
/// Where a request goes, from its absolute `http` or `https` URL.
pub struct Target {
  /// The host to dial: a name, an IPv4 address, or an IPv6 address without
  /// brackets.
  host : String
  port : Int32
  secure : Bool
  /// `host:port`, IPv6 in brackets: what `Dialed` reports.
  address : String
  /// The `:authority`: the host, with the port unless it is the scheme's.
  authority : String
  /// `scheme://host:port`: the key connections are kept under.
  origin : String
  /// The `:path`: the path and query, `/` for an empty path.
  path : String
}

///|
/// Validates `request` and parses its URL. A relative URL, a scheme other
/// than http and https, a URL without a host or with userinfo is refused
/// with `Invalid` in phase Pool. The fragment is never sent.
pub fn target(
  request : @mttp_core.Request,
) -> Target raise @mttp_core.TransportError {
  request.validate()
  let url = @mttp_core.Url::parse(request.url) catch {
    _ => raise invalid("not a URL: \{request.url}")
  }
  guard url.scheme is Some("http" | "https" as scheme) &&
    url.host is Some(host) &&
    !host.is_empty() &&
    url.userinfo is None &&
    url.port_or_default() is Some(port) else {
    raise invalid(
      "the client requires an absolute http(s) URL without userinfo",
    )
  }
  let name = if host.contains(":") { "[" + host + "]" } else { host }
  let address = name + ":" + port.to_string()
  let default_port = if scheme == "https" { 443 } else { 80 }
  {
    host,
    port,
    secure: scheme == "https",
    address,
    authority: if port == default_port {
      name
    } else {
      address
    },
    origin: scheme + "://" + address,
    path: (if url.path.is_empty() { "/" } else { url.path }) +
    (match url.query {
      Some(q) => "?" + q
      None => ""
    }),
  }
}

///|
/// Fields HTTP/2 and HTTP/3 forbid in a message, and Host,
/// which `:authority` replaces.
pub let connection_fields : Array[String] = [
  "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade",
  "host",
]

///|
/// The request's header block: the pseudo fields, then the request's own
/// fields with lowercase names. A Host field becomes `:authority`;
/// connection-specific fields are left out, and TE only as `trailers`.
/// The request's own `Proxy-Authorization` is left out too, as h1client
/// drops it on every route: a proxy's credentials go on its CONNECT, never
/// to the origin through its tunnel (Codex's review of #62).
/// Content-Length is written for a body of known length, as the HTTP/1
/// client frames it: an empty body only for POST, PUT and PATCH.
pub fn request_fields(
  request : @mttp_core.Request,
  target : Target,
) -> Array[(String, String)] {
  let authority = request.headers.get("host").unwrap_or(target.authority)
  let fields = [
    (":method", request.meth.to_string()),
    (":scheme", if target.secure { "https" } else { "http" }),
    (":authority", authority),
    (":path", target.path),
  ]
  for field in request.headers.iter() {
    let (name, value) = field
    let name = name.to_lower()
    if connection_fields.contains(name) ||
      name is ("content-length" | "proxy-authorization") {
      continue
    }
    if name == "te" && value.trim(chars=" \t").to_lower() != "trailers" {
      continue
    }
    fields.push((name, value))
  }
  match request.body.length() {
    Some(0L) if !(request.meth is (Post | Put | Patch)) => ()
    Some(n) => fields.push(("content-length", n.to_string()))
    None => ()
  }
  fields
}

///|
/// The fields of a trailer section to send, or why it cannot be sent:
/// fields that fail validation, the connection-specific ones HTTP/2 and
/// HTTP/3 forbid in any section, and those that would change framing or
/// routing if a recipient merged them into the head (Content-Length, TE,
/// Trailer; RFC 9110, section 6.5.1), as gaato/mttp_core's HTTP/1.1
/// encoder refuses them.
pub fn trailer_fields(
  trailers : @mttp_core.Headers,
) -> Result[Array[(String, String)], String] {
  trailers.validate() catch {
    @mttp_core.TransportError(detail~, ..) => return Err(detail)
  }
  let fields = []
  for field in trailers.iter() {
    let name = field.0.to_lower()
    if connection_fields.contains(name) ||
      name is ("content-length" | "te" | "trailer") {
      return Err("\{name} cannot be a trailer field")
    }
    fields.push((name, field.1))
  }
  Ok(fields)
}

///|
/// The response head in `fields`: `Ok(None)` for an interim (1xx) response,
/// `Err` for one that is not a valid response. nghttp2 and nghttp3 already
/// refused misplaced or unknown pseudo fields and connection-specific ones
/// (RFC 9113, section 8.3).
pub fn response_head(
  fields : Array[(String, String)],
) -> Result[(Int32, @mttp_core.Headers)?, String] {
  guard fields is [(":status", status), .. rest] else {
    return Err("a response without :status first")
  }
  guard status.length() == 3 && status.iter().all(c => c >= '0' && c <= '9') else {
    return Err("an invalid :status \{status}")
  }
  let code = (status.get_char(0).unwrap().to_int() - '0'.to_int()) * 100 +
    (status.get_char(1).unwrap().to_int() - '0'.to_int()) * 10 +
    (status.get_char(2).unwrap().to_int() - '0'.to_int())
  if code == 101 {
    return Err(
      "101 is not allowed in HTTP/2 or HTTP/3 (RFC 9113, section 8.6; RFC 9114, section 4.5)",
    )
  }
  if code < 200 {
    return Ok(None)
  }
  let mut headers = @mttp_core.Headers::empty()
  for field in rest {
    let (name, value) = field
    if name.has_prefix(":") {
      return Err("a pseudo field after the regular ones: \{name}")
    }
    headers = headers.add(name, value)
  }
  Ok(Some((code, headers)))
}

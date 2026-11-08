///|
/// Where a request goes, from its absolute `http` or `https` URL.
priv struct Target {
  /// The host to dial: a name, an IPv4 address, or an IPv6 address without
  /// brackets.
  host : String
  port : Int32
  secure : Bool
  /// The `Host` field: the authority without the scheme's default port.
  host_field : String
  /// `scheme://host:port` with the port always written, the key that parks and counts connections.
  origin : String
  /// The request target in origin form, or the authority for CONNECT.
  path : String
}

///|
/// Validates `request` and parses its URL. A relative URL, a scheme other
/// than http and https, a URL without a host or with userinfo is refused
/// with `Invalid` in phase Pool. The fragment is never sent.
fn target(request : @http.Request) -> Target raise @http.TransportError {
  request.validate()
  let url = @http.Url::parse(request.url) catch {
    _ => raise invalid("invalid URL")
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
  let authority = name + ":" + port.to_string()
  let default_port = if scheme == "https" { 443 } else { 80 }
  let path = if request.meth == Connect {
    authority
  } else {
    (if url.path.is_empty() { "/" } else { url.path }) +
    (match url.query {
      Some(q) => "?" + q
      None => ""
    })
  }
  {
    host,
    port,
    secure: scheme == "https",
    host_field: if port == default_port {
      name
    } else {
      authority
    },
    origin: scheme + "://" + authority,
    path,
  }
}

///|
// The socket implementation consumes the separated address fields; fetch
// consumes only the canonical origin and path.
#warnings("-unused_field")
pub(all) struct Target {
  host : String
  port : Int32
  secure : Bool
  authority : String
  origin : String
  path : String
}

///|
pub fn target(request : @model.Request) -> Target raise @model.TransportError {
  request.validate()
  let url = @model.Url::parse(request.url) catch {
    _ =>
      raise @model.TransportError(
        kind=Invalid,
        phase=Pool,
        detail="invalid URL",
      )
  }
  guard url.scheme is Some("http" | "https") &&
    url.host is Some(host) &&
    !host.is_empty() &&
    url.userinfo is None &&
    url.port_or_default() is Some(port) else {
    raise @model.TransportError(
      kind=Invalid,
      phase=Pool,
      detail="backend requires an absolute http(s) URL without userinfo",
    )
  }
  let host_field = if host.contains(":") { "[" + host + "]" } else { host }
  let authority = host_field + ":" + port.to_string()
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
    secure: url.scheme == Some("https"),
    authority,
    origin: url.scheme.unwrap() + "://" + authority,
    path,
  }
}

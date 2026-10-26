///|
/// A proxy server: where to dial, and what to tell it.
pub(all) struct ProxyServer {
  /// `http://host:port` or `https://host:port`, the port always written.
  origin : String
  /// `Basic` credentials from the proxy URL's userinfo, for the
  /// `Proxy-Authorization` header. They go to the proxy alone.
  authorization : String?
}

///|
/// How a request reaches its origin.
pub(all) enum Route {
  Direct
  /// An `http://` request handed to the proxy, its target in absolute form
  /// (RFC 9112 §3.2.2), on a connection to the proxy.
  Forward(ProxyServer)
  /// An `https://` request sent through a tunnel the proxy opens with
  /// `CONNECT` (RFC 9110 §9.3.6), TLS running end to end inside it.
  Tunnel(ProxyServer)
}

///|
/// The proxies a transport uses, fixed when it is made: one for `http://`
/// requests and one for `https://`, each a server or why the setting
/// cannot be used, and the hosts that skip them. A request whose proxy
/// setting is unusable fails rather than going direct.
pub(all) struct Proxies {
  http : Result[ProxyServer, String]?
  https : Result[ProxyServer, String]?
  bypass : Array[NoProxyRule]
}

///|
/// The proxies for an explicit `proxy` URL, which carries every request
/// (httpx's `proxy=`), or else, when `trust_env`, those the environment
/// names through `lookup`, as curl and httpx read it:
/// - `http_proxy` for `http://` requests, `https_proxy` for `https://`,
///   `all_proxy` for either when its own is unset;
/// - `no_proxy` for the hosts that go direct (`parse_no_proxy`);
/// - each name in lower case first, then upper case; an empty value is
///   unset. Upper-case `HTTP_PROXY` is ignored when `REQUEST_METHOD` is
///   set, since a CGI program gets it from a request's `Proxy` header
///   (httpoxy, CVE-2016-5385), as Go and Python ignore it.
pub fn configure_proxies(
  proxy : String?,
  trust_env~ : Bool,
  lookup : (String) -> String?,
) -> Proxies {
  if proxy is Some(text) {
    let server = Some(parse_proxy(text, source="proxy"))
    return { http: server, https: server, bypass: [], }
  }
  guard trust_env else { return { http: None, https: None, bypass: [], } }
  let cgi = lookup("REQUEST_METHOD") is Some(value) && !value.is_empty()
  let all = env_value(lookup, "all_proxy", upper=true)
  let setting = (own : (String, String)?) => {
    guard (if own is Some(_) { own } else { all }) is Some((name, value)) else {
      None
    }
    Some(parse_proxy(value, source=name))
  }
  {
    http: setting(env_value(lookup, "http_proxy", upper=!cgi)),
    https: setting(env_value(lookup, "https_proxy", upper=true)),
    bypass: match env_value(lookup, "no_proxy", upper=true) {
      Some((_, value)) => parse_no_proxy(value)
      None => []
    },
  }
}

///|
/// The first non-empty of `name` and, when `upper`, its upper-case form,
/// with the spelling found.
pub fn env_value(
  lookup : (String) -> String?,
  name : String,
  upper~ : Bool,
) -> (String, String)? {
  let names = if upper { [name, name.to_upper()] } else { [name] }
  for candidate in names {
    if lookup(candidate) is Some(value) && !value.trim().is_empty() {
      return Some((candidate, value.trim().to_owned()))
    }
  }
  None
}

///|
/// The proxy at `text`: `http://` or `https://`, a scheme taken as `http://`
/// when missing (curl, httpx's environment), the port as the scheme's
/// default when missing, and `user:password@` percent-decoded into `Basic`
/// credentials. A path is ignored. `source` names the setting in the error.
pub fn parse_proxy(
  text : String,
  source~ : String,
) -> Result[ProxyServer, String] {
  let text = text.trim().to_owned()
  let text = if text.contains("://") { text } else { "http://" + text }
  let url = @model.Url::parse(text) catch {
    @model.UrlError::Invalid(reason) =>
      return Err("invalid \{source} URL: \{reason}")
  }
  let scheme = url.scheme.unwrap_or("")
  guard scheme is ("http" | "https") else {
    return Err(
      "unsupported \{source} scheme \{scheme}: only http and https proxies are supported",
    )
  }
  guard url.host is Some(host) && !host.is_empty() else {
    return Err("invalid \{source} URL: no host")
  }
  let authorization = match url.userinfo {
    None => None
    Some(userinfo) =>
      match basic_credentials(userinfo) {
        Some(credentials) => Some(credentials)
        None => return Err("invalid \{source} URL: malformed credentials")
      }
  }
  let host = if host.contains(":") { "[" + host + "]" } else { host }
  let port = url.port_or_default().unwrap_or(80)
  Ok({ origin: "\{scheme}://\{host}:\{port}", authorization, })
}

///|
/// `Basic` credentials (RFC 7617) for a URL's userinfo, its user and
/// password percent-decoded; a userinfo without `:` is a user with an empty
/// password, as httpx takes it.
pub fn basic_credentials(userinfo : String) -> String? {
  let (user, password) = match userinfo.find(":") {
    Some(colon) => (userinfo[:colon], userinfo[colon + 1:])
    None => (userinfo[:], "")
  }
  let user = @model.percent_decode(user.to_owned()) catch { _ => return None }
  let password = @model.percent_decode(password.to_owned()) catch {
    _ => return None
  }
  @model.Request::get("/").basic(user, password).headers.get("authorization")
}

///|
/// The route of a request to `origin`: direct when its scheme has no proxy
/// or `bypass` names its host, otherwise forwarded (`http://`) or tunnelled
/// (`https://`). A request is routed by its own URL, so a redirect to another
/// origin is routed afresh. An unusable proxy setting raises `Protocol`
/// before anything is sent.
pub fn Proxies::route(
  self : Proxies,
  origin : Target,
) -> Route raise @model.TransportError {
  guard (if origin.secure { self.https } else { self.http }) is Some(setting) else {
    return Direct
  }
  if bypasses_proxy(self.bypass, origin.host, origin.port) {
    return Direct
  }
  match setting {
    Ok(server) => if origin.secure { Tunnel(server) } else { Forward(server) }
    Err(message) =>
      raise @model.TransportError(kind=Protocol, phase=Pool, detail=message)
  }
}

///|
/// The key that parks and counts connections for `origin` on this route: a
/// connection to the proxy or through its tunnel is never handed to a
/// request that goes direct, or through another proxy.
pub fn Route::key(self : Route, origin : String) -> String {
  match self {
    Direct => origin
    Forward(server) | Tunnel(server) => origin + " via " + server.origin
  }
}

///|
/// The request target: CONNECT uses its authority on every route; other
/// requests use `path` directly or an absolute URL through a forward proxy.
pub fn Route::target(
  self : Route,
  origin : String,
  path : String,
  meth : @model.Method,
) -> String {
  if meth == Connect {
    return path
  }
  match self {
    Forward(_) => origin + path
    Direct | Tunnel(_) => path
  }
}

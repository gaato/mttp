///|
/// Which HTTP proxies a `Client` uses, as data fixed at construction: one
/// URL for `http://` requests, one for `https://` requests, and a
/// `NO_PROXY` list of the hosts that go direct. Build it with `none`,
/// `fixed` or `from_env`, or as a record.
///
/// A proxy URL is `http://` or `https://` (a missing scheme is `http://`),
/// with an optional `user:password@` that becomes `Proxy-Authorization:
/// Basic` for that proxy alone. `http://` requests are forwarded with an
/// absolute target; `https://` requests go through a `CONNECT` tunnel, with
/// TLS end to end inside it. A setting that cannot be used fails the
/// requests it would carry with `Protocol` in phase Pool, rather than
/// sending them direct.
///
/// ```mbt check
/// test {
///   let env = {
///     "https_proxy": "http://proxy.test:3128",
///     "NO_PROXY": "internal.test",
///   }
///   let proxy = @h1client.ProxyConfig::from_env(name => env.get(name))
///   assert_eq(proxy.http, None)
///   assert_eq(proxy.https, Some("http://proxy.test:3128"))
///   assert_eq(proxy.no_proxy, "internal.test")
/// }
/// ```
#derive(Eq, Debug)
pub(all) struct ProxyConfig {
  /// The proxy for `http://` requests, or `None` to send them direct.
  http : String?
  /// The proxy for `https://` requests, or `None` to send them direct.
  https : String?
  /// Hosts that skip the proxies, as curl reads `NO_PROXY`: comma-separated
  /// names (each with its subdomains), `*`, IPv4 and IPv6 addresses and
  /// `/prefix` networks, each optionally restricted to a `:port`. Names are
  /// never resolved; entries of no known form are skipped.
  no_proxy : String
}

///|
/// Compares proxy settings.
pub extend ProxyConfig with Eq::{equal, not_equal}

///|
/// Formats proxy settings for diagnostics; they may hold credentials.
pub extend ProxyConfig with @debug.Debug::{to_repr}

///|
/// Every request goes direct.
pub fn ProxyConfig::none() -> ProxyConfig {
  { http: None, https: None, no_proxy: "", }
}

///|
/// Every request goes through the proxy at `url`, as httpx's `proxy=`.
pub fn ProxyConfig::fixed(url : String) -> ProxyConfig {
  { http: Some(url), https: Some(url), no_proxy: "", }
}

///|
/// The proxies the environment names, read once through `lookup`, as curl
/// and httpx read them:
///
/// - `http_proxy` for `http://` requests, `https_proxy` for `https://`, and
///   `all_proxy` for either when its own is unset;
/// - `no_proxy` for the hosts that go direct;
/// - each name in lower case first, then upper case; a value of only
///   spaces is unset. Upper-case `HTTP_PROXY` is ignored when
///   `REQUEST_METHOD` is set, since a CGI program gets it from a request's
///   `Proxy` header (httpoxy, CVE-2016-5385), as Go and Python ignore it.
///
/// The client never reads the environment itself; `lookup` is called here
/// and nowhere else.
pub fn ProxyConfig::from_env(lookup : (String) -> String?) -> ProxyConfig {
  let cgi = lookup("REQUEST_METHOD") is Some(value) && !value.is_empty()
  let all = env_value(lookup, "all_proxy", upper=true)
  let own = (value : String?) => if value is Some(_) { value } else { all }
  {
    http: own(env_value(lookup, "http_proxy", upper=!cgi)),
    https: own(env_value(lookup, "https_proxy", upper=true)),
    no_proxy: env_value(lookup, "no_proxy", upper=true).unwrap_or(""),
  }
}

///|
/// The first value of `name`, then of its upper-case form when `upper`,
/// that is not blank, trimmed.
fn env_value(
  lookup : (String) -> String?,
  name : String,
  upper~ : Bool,
) -> String? {
  let names = if upper { [name, name.to_upper()] } else { [name] }
  for candidate in names {
    if lookup(candidate) is Some(value) && !value.trim().is_empty() {
      return Some(value.trim().to_owned())
    }
  }
  None
}

///|
/// A proxy server: where to dial, and what to tell it.
priv struct ProxyServer {
  host : String
  port : Int32
  secure : Bool
  /// `http://host:port` or `https://host:port`, the port always written.
  origin : String
  /// `Basic` credentials from the proxy URL's userinfo; they go to the
  /// proxy alone.
  authorization : String?
}

///|
/// How a request reaches its origin.
priv enum Route {
  Direct
  /// An `http://` request handed to the proxy with its target in absolute
  /// form (RFC 9112 §3.2.2).
  Forward(ProxyServer)
  /// An `https://` request sent through a tunnel the proxy opens with
  /// `CONNECT` (RFC 9110 §9.3.6), TLS running end to end inside it.
  Tunnel(ProxyServer)
}

///|
/// A `ProxyConfig` parsed once: each scheme's proxy or why it cannot be
/// used, and the bypass rules.
priv struct Proxies {
  http : Result[ProxyServer, String]?
  https : Result[ProxyServer, String]?
  bypass : Array[NoProxyRule]
}

///|
fn Proxies::new(config : ProxyConfig) -> Proxies {
  {
    http: config.http.map(url => parse_proxy(url, scheme="http")),
    https: config.https.map(url => parse_proxy(url, scheme="https")),
    bypass: parse_no_proxy(config.no_proxy),
  }
}

///|
/// The proxy at `text`, set for requests of `scheme`: `http://` or
/// `https://`, a missing scheme taken as `http://` (curl, httpx), a missing
/// port as the scheme's default, and `user:password@` percent-decoded into
/// `Basic` credentials. A path is ignored. Error messages never repeat the
/// URL, which may hold credentials.
fn parse_proxy(text : String, scheme~ : String) -> Result[ProxyServer, String] {
  let source = "\{scheme} proxy"
  let text = text.trim().to_owned()
  let text = if text.contains("://") { text } else { "http://" + text }
  let url = @http.Url::parse(text) catch {
    @http.UrlError::Invalid(reason) =>
      return Err("invalid \{source} URL: \{reason}")
  }
  let proxy_scheme = url.scheme.unwrap_or("")
  guard proxy_scheme is ("http" | "https") else {
    return Err(
      "unsupported \{source} scheme \{proxy_scheme}: only http and https proxies are supported",
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
  let secure = proxy_scheme == "https"
  let port = url.port_or_default().unwrap_or(if secure { 443 } else { 80 })
  let name = if host.contains(":") { "[" + host + "]" } else { host }
  Ok({
    host,
    port,
    secure,
    origin: "\{proxy_scheme}://\{name}:\{port}",
    authorization,
  })
}

///|
/// `Basic` credentials (RFC 7617) for a URL's userinfo, its user and
/// password percent-decoded; a userinfo without `:` is a user with an empty
/// password, as httpx takes it.
fn basic_credentials(userinfo : String) -> String? {
  let (user, password) = match userinfo.find(":") {
    Some(colon) => (userinfo[:colon], userinfo[colon + 1:])
    None => (userinfo[:], "")
  }
  let user = @http.percent_decode(user.to_owned()) catch { _ => return None }
  let password = @http.percent_decode(password.to_owned()) catch {
    _ => return None
  }
  @http.Request::get("/").basic(user, password).headers.get("authorization")
}

///|
/// The route of a request to `target`: direct when its scheme has no proxy
/// or the bypass rules name its host, otherwise forwarded (`http://`) or
/// tunnelled (`https://`). Each request is routed by its own URL. An
/// unusable proxy setting raises `Protocol` in phase Pool, before anything
/// is sent.
fn Proxies::route(
  self : Proxies,
  target : Target,
) -> Route raise @http.TransportError {
  guard (if target.secure { self.https } else { self.http }) is Some(setting) else {
    return Direct
  }
  if bypasses_proxy(self.bypass, target.host, target.port) {
    return Direct
  }
  match setting {
    Ok(server) => if target.secure { Tunnel(server) } else { Forward(server) }
    Err(message) =>
      raise @http.TransportError(kind=Protocol, phase=Pool, detail=message)
  }
}

///|
/// The key that parks and counts connections for `origin` on this route:
/// a connection to a proxy or through its tunnel is never handed to a
/// request that goes direct, or through another proxy.
fn Route::key(self : Route, origin : String) -> String {
  match self {
    Direct => origin
    Forward(server) | Tunnel(server) => origin + " via " + server.origin
  }
}

///|
/// The request target: origin form directly and through a tunnel, absolute
/// form to a forward proxy; a CONNECT keeps its authority on every route.
fn Route::target(self : Route, target : Target, meth : @http.Method) -> String {
  match self {
    Forward(_) if meth != Connect => "http://" + target.host_field + target.path
    _ => target.path
  }
}

///|
/// The headers as this route sends them: the request's own
/// `Proxy-Authorization` is always dropped, and a forward proxy's
/// credentials are added; a tunnel's go on its CONNECT instead.
fn Route::headers(self : Route, headers : @http.Headers) -> @http.Headers {
  let headers = headers.remove("proxy-authorization")
  match self {
    Forward({ authorization: Some(auth), .. }) =>
      headers.add("proxy-authorization", auth)
    _ => headers
  }
}

///|
/// Opens a connection for `route`: to the origin, or to the proxy, through
/// whose tunnel TLS then runs to the origin. A connection carries at most
/// two TLS layers, the proxy's and the origin's.
async fn dial_route(
  dialer : &@rt.Dialer,
  target : Target,
  route : Route,
  agent : String?,
  limits : @h1.Limits,
) -> Wire raise @http.TransportError {
  match route {
    Direct => Wire::dial(dialer, target.host, target.port, target.secure)
    Forward(proxy) => Wire::dial(dialer, proxy.host, proxy.port, proxy.secure)
    Tunnel(proxy) => {
      let wire = Wire::dial(dialer, proxy.host, proxy.port, proxy.secure)
      errdefer wire.close()
      open_tunnel(wire, target, proxy, agent, limits)
      wire.conn = dialer.start_tls(wire.conn, host=target.host)
      wire
    }
  }
}

///|
/// Asks the proxy for a tunnel to `target` and reads its answer within
/// `limits`, all in phase Dial: a refusal (3xx and above) is
/// `Proxy(status)`; a malformed answer, 101, more than 16 informational
/// heads, or bytes after a successful answer are `Protocol`.
async fn open_tunnel(
  wire : Wire,
  target : Target,
  proxy : ProxyServer,
  agent : String?,
  limits : @h1.Limits,
) -> Unit raise @http.TransportError {
  let mut headers = @http.Headers::of([("host", target.authority)])
  if proxy.authorization is Some(auth) {
    headers = headers.add("proxy-authorization", auth)
  }
  if agent is Some(agent) {
    headers = headers.add("user-agent", agent)
  }
  let head = @h1.write_request_head(
    Connect,
    target.authority,
    headers,
    NoBody,
    Http11,
  ) catch {
    @h1.ParseError(detail~, ..) => raise invalid(detail)
  }
  wire.write(head)
  for _ in 0..<17 {
    let answer = wire.head(limits, phase=Dial)
    if answer.status >= 300 {
      raise @http.TransportError(
        kind=Proxy(status=answer.status),
        phase=Dial,
        detail="the proxy refused CONNECT",
      )
    }
    if answer.status >= 200 {
      if !wire.pending.is_empty() {
        raise @http.TransportError(
          kind=Protocol,
          phase=Dial,
          detail="unexpected bytes after the proxy's CONNECT answer",
        )
      }
      return
    }
    if answer.status == 101 {
      break
    }
  }
  raise @http.TransportError(
    kind=Protocol,
    phase=Dial,
    detail="invalid informational answer to CONNECT",
  )
}

///|
fn describe_server(server : ProxyServer) -> String {
  match server.authorization {
    None => server.origin
    Some(credentials) => server.origin + " (" + credentials + ")"
  }
}

///|
fn describe_setting(setting : Result[ProxyServer, String]?) -> String {
  match setting {
    None => "none"
    Some(Ok(server)) => describe_server(server)
    Some(Err(message)) => "error: " + message
  }
}

///|
/// How `proxies` sends a GET for `url`: its route, the key its connection
/// is parked under, and its request target.
fn describe_route(proxies : Proxies, url : String) -> String {
  let origin = target(@mttp_core.Request::get(url)) catch {
    error => return "unexpected: " + @debug.to_string(error)
  }
  let route = proxies.route(origin) catch {
    @mttp_core.TransportError(kind=Protocol, phase=Pool, detail=message) =>
      return "Protocol: " + message
    error => return "unexpected: " + @debug.to_string(error)
  }
  let how = match route {
    Direct => "direct"
    Forward(server) => "forward to " + describe_server(server)
    Tunnel(server) => "tunnel via " + describe_server(server)
  }
  how +
  " | key " +
  route.key(origin.origin) +
  " | target " +
  route.target(origin, Get)
}

///|
fn env_of(pairs : Array[(String, String)]) -> (String) -> String? {
  let map = Map::from_array(pairs)
  name => map.get(name)
}

///|
test "parse_proxy takes http and https proxy URLs with Basic credentials" {
  for
    (text, expected) in [
      ("http://proxy:3128", "http://proxy:3128"),
      ("  http://proxy:3128  ", "http://proxy:3128"),
      ("proxy:3128", "http://proxy:3128"),
      ("http://proxy", "http://proxy:80"),
      ("https://proxy", "https://proxy:443"),
      ("https://proxy:443", "https://proxy:443"),
      ("HTTP://Proxy.Example:3128/ignored/path?q", "http://proxy.example:3128"),
      ("http://[::1]:3128", "http://[::1]:3128"),
      (
        "http://user:pa%20ss@proxy:3128", "http://proxy:3128 (Basic dXNlcjpwYSBzcw==)",
      ),
      ("http://user@proxy:1", "http://proxy:1 (Basic dXNlcjo=)"),
      (
        "http://user:se%40cret@proxy:1", "http://proxy:1 (Basic dXNlcjpzZUBjcmV0)",
      ),
      ("http://user:p%C3%A9@proxy:1", "http://proxy:1 (Basic dXNlcjpww6k=)"),
      (
        "http://user:p%FF@proxy:1", "error: invalid https proxy URL: malformed credentials",
      ),
      (
        "http://u%FF:p@proxy:1", "error: invalid https proxy URL: malformed credentials",
      ),
      (
        "socks5://proxy:1080", "error: unsupported https proxy scheme socks5: only http and https proxies are supported",
      ),
      ("http:///path", "error: invalid https proxy URL: no host"),
    ] {
    assert_eq(
      describe_setting(Some(parse_proxy(text, scheme="https"))),
      expected,
      msg=text,
    )
  }
  // The URL parser's own refusals are named as the setting's, and the URL
  // with its credentials is not repeated.
  let refused = describe_setting(
    Some(parse_proxy("http://user:secret@proxy:99999", scheme="http")),
  )
  assert_true(refused.has_prefix("error: invalid http proxy URL: "))
  assert_false(refused.contains("secret"))
}

///|
test "ProxyConfig reads the environment as curl and httpx do" {
  let env = env_of([
    ("http_proxy", "http://lower:1"),
    ("HTTP_PROXY", "http://upper:1"),
    ("HTTPS_PROXY", "secure:2"),
    ("NO_PROXY", "skip.test"),
  ])
  let rows : Array[((String) -> String?, (String?, String?, String))] = [
    (env, (Some("http://lower:1"), Some("secure:2"), "skip.test")),
    (env_of([]), (None, None, "")),
    // Lower case first, upper case when the lower is unset or blank.
    (
      env_of([("http_proxy", " "), ("HTTP_PROXY", "http://upper:1")]),
      (Some("http://upper:1"), None, ""),
    ),
    // ALL_PROXY stands in for a scheme without its own.
    (
      env_of([("ALL_PROXY", "http://all:3"), ("https_proxy", "https://own:4")]),
      (Some("http://all:3"), Some("https://own:4"), ""),
    ),
    (
      env_of([("all_proxy", "http://all:3")]),
      (Some("http://all:3"), Some("http://all:3"), ""),
    ),
    // In a CGI program, upper-case HTTP_PROXY may come from a request
    // header and is ignored; the lower-case one and the others are not.
    (
      env_of([
        ("REQUEST_METHOD", "GET"),
        ("HTTP_PROXY", "http://evil:1"),
        ("HTTPS_PROXY", "http://s:2"),
      ]),
      (None, Some("http://s:2"), ""),
    ),
    (
      env_of([("REQUEST_METHOD", "GET"), ("http_proxy", "http://ok:1")]),
      (Some("http://ok:1"), None, ""),
    ),
    (
      env_of([
        ("REQUEST_METHOD", "GET"),
        ("HTTP_PROXY", "http://evil:1"),
        ("ALL_PROXY", "http://all:3"),
      ]),
      (Some("http://all:3"), Some("http://all:3"), ""),
    ),
    (
      env_of([("no_proxy", " a.test, b.test "), ("NO_PROXY", "c.test")]),
      (None, None, "a.test, b.test"),
    ),
  ]
  for row in rows {
    let (lookup, expected) = row
    let config = ProxyConfig::from_env(lookup)
    assert_eq((config.http, config.https, config.no_proxy), expected)
  }
  assert_eq(ProxyConfig::fixed("http://p:1"), {
    http: Some("http://p:1"),
    https: Some("http://p:1"),
    no_proxy: "",
  })
  assert_eq(ClientConfig::default().proxy, ProxyConfig::none())
  // A setting that cannot be used is kept as its error.
  let proxies = Proxies::new({
    ..ProxyConfig::none(),
    https: Some("socks5://s:1"),
  })
  assert_eq(
    describe_setting(proxies.https),
    "error: unsupported https proxy scheme socks5: only http and https proxies are supported",
  )
  assert_eq(describe_setting(proxies.http), "none")
}

///|
test "each request is routed by its own URL" {
  let proxies = Proxies::new({
    http: Some("http://u:p@proxy:3128"),
    https: Some("http://proxy:3128"),
    no_proxy: "internal.test,10.0.0.0/8,[::1]:8443",
  })
  for
    (origin, expected) in [
      (
        "http://api.test", "forward to http://proxy:3128 (Basic dTpw) | key http://api.test:80 via http://proxy:3128 | target http://api.test/",
      ),
      (
        "http://api.test:8080/p?q", "forward to http://proxy:3128 (Basic dTpw) | key http://api.test:8080 via http://proxy:3128 | target http://api.test:8080/p?q",
      ),
      (
        "https://api.test/p", "tunnel via http://proxy:3128 | key https://api.test:443 via http://proxy:3128 | target /p",
      ),
      (
        "https://internal.test/p", "direct | key https://internal.test:443 | target /p",
      ),
      (
        "http://a.internal.test/p", "direct | key http://a.internal.test:80 | target /p",
      ),
      ("http://10.1.2.3/p", "direct | key http://10.1.2.3:80 | target /p"),
      ("https://[::1]:8443/p", "direct | key https://[::1]:8443 | target /p"),
      (
        "https://[::1]/p", "tunnel via http://proxy:3128 | key https://[::1]:443 via http://proxy:3128 | target /p",
      ),
    ] {
    assert_eq(describe_route(proxies, origin), expected, msg=origin)
  }
  // Without proxies every request goes direct.
  assert_eq(
    describe_route(Proxies::new(ProxyConfig::none()), "https://api.test/p"),
    "direct | key https://api.test:443 | target /p",
  )
}

///|
test "an unusable proxy setting fails its requests unless NO_PROXY skips it" {
  let proxies = Proxies::new({
    http: None,
    https: Some("ftp://proxy:21"),
    no_proxy: "skip.test",
  })
  assert_eq(
    describe_route(proxies, "https://api.test/p"),
    "Protocol: unsupported https proxy scheme ftp: only http and https proxies are supported",
  )
  assert_eq(
    describe_route(proxies, "https://skip.test/p"),
    "direct | key https://skip.test:443 | target /p",
  )
  assert_eq(
    describe_route(proxies, "http://api.test/p"),
    "direct | key http://api.test:80 | target /p",
  )
}

///|
test "connections through different proxies, or none, are kept apart" {
  let a = parse_proxy("http://a:1", scheme="https").unwrap()
  let b = parse_proxy("http://b:1", scheme="https").unwrap()
  let keys = [
    Direct.key("https://api.test:443"),
    Tunnel(a).key("https://api.test:443"),
    Tunnel(b).key("https://api.test:443"),
    Forward(a).key("http://api.test:80"),
    Direct.key("http://api.test:80"),
  ]
  for i, key in keys {
    for j, other in keys {
      assert_eq(key == other, i == j, msg="\{key} vs \{other}")
    }
  }
}

// URL patterns (the WHATWG URL Pattern Standard), without regular
// expressions: what RFC 9842 asks of a dictionary's `match`.

///|
/// Why a pattern could not be made.
#derive(Eq, Debug)
pub(all) suberror PatternError {
  /// The standard refuses it (it would throw a TypeError).
  Invalid(String)
  /// It has a regular expression group, which this package does not run
  /// and RFC 9842 does not allow in `match`.
  RegexpGroup
  /// Valid, but past what this package implements, such as a hostname that
  /// needs IDNA.
  Unsupported(String)
}

///|
/// Compares errors by kind and reason.
pub extend PatternError with Eq::{equal, not_equal}

///|
/// Debug representation of an error.
pub extend PatternError with @debug.Debug::{to_repr}

///|
/// Shows the error.
pub impl Show for PatternError with fn output(self, logger) {
  match self {
    Invalid(why) => logger.write_string("invalid URL pattern: \{why}")
    RegexpGroup => logger.write_string("URL pattern with a regular expression")
    Unsupported(why) => logger.write_string("unsupported URL pattern: \{why}")
  }
}

///|
/// Shows the error.
pub extend PatternError with Show::{output, to_string}

///|
/// The components of a pattern or a URL as separate strings, as the
/// standard's URLPatternInit holds them; `None` is a component not given.
#derive(Eq, Debug)
pub(all) struct PatternInit {
  mut protocol : String?
  mut username : String?
  mut password : String?
  mut hostname : String?
  mut port : String?
  mut pathname : String?
  mut search : String?
  mut hash : String?
  mut base_url : @mttp_core.Url?
}

///|
/// Compares inits component by component.
pub extend PatternInit with Eq::{equal, not_equal}

///|
/// Debug representation of an init.
pub extend PatternInit with @debug.Debug::{to_repr}

///|
/// An init with no component given.
pub fn PatternInit::new(
  protocol? : String,
  username? : String,
  password? : String,
  hostname? : String,
  port? : String,
  pathname? : String,
  search? : String,
  hash? : String,
  base_url? : @mttp_core.Url,
) -> PatternInit {
  {
    protocol,
    username,
    password,
    hostname,
    port,
    pathname,
    search,
    hash,
    base_url,
  }
}

///|
priv struct Component {
  pattern : String
  matcher : Matcher
}

///|
fn Component::matches(self : Component, input : String) -> Bool {
  self.matcher.matches(input)
}

///|
/// Parses and compiles one component; a regular expression group is
/// refused here, as RFC 9842 refuses it.
fn compile_component(
  input : String,
  encode : (String) -> String raise PatternError,
  options : Options,
) -> Component raise PatternError {
  let parts = parse_pattern(input, options, encode)
  guard !parts.iter().any(p => p.kind == Regexp) else { raise RegexpGroup }
  {
    pattern: pattern_string(parts, options),
    matcher: Matcher::new(parts, options),
  }
}

///|
/// A compiled URL pattern: one pattern per component.
pub struct UrlPattern {
  priv protocol : Component
  priv username : Component
  priv password : Component
  priv hostname : Component
  priv port : Component
  priv pathname : Component
  priv search : Component
  priv hash : Component
}

///|
fn serialized_path(url : @mttp_core.Url) -> String {
  if url.path == "" && url.scheme is Some(s) && special_schemes.contains(s) {
    "/"
  } else {
    url.path
  }
}

///|
fn has_opaque_path(url : @mttp_core.Url) -> Bool {
  url.scheme is Some(_) && url.host is None && !url.path.has_prefix("/")
}

///|
fn split_userinfo(url : @mttp_core.Url) -> (String, String) {
  match url.userinfo {
    None => ("", "")
    Some(info) =>
      match info.find(":") {
        Some(i) => (info[:i].to_owned(), info[i + 1:].to_owned())
        None => (info, "")
      }
  }
}

///|
/// The host as the WHATWG host serializer writes it: `Url` keeps an IPv6
/// address without its brackets.
fn url_host(host : String?) -> String {
  match host {
    None => ""
    Some(h) => if h.contains(":") { "[\{h}]" } else { h }
  }
}

///|
fn is_absolute_pathname(input : String, pattern : Bool) -> Bool {
  if input.has_prefix("/") {
    return true
  }
  pattern && (input.has_prefix("\\/") || input.has_prefix("{/"))
}

///|
/// The components of `url` as WHATWG's URL parser would keep them: `Url`
/// follows RFC 3986, so its host, port, path and query go through the same
/// canonicalization a pattern's do (IPv4 numbers, default ports, dot
/// segments, percent-encoding).
priv struct Whatwg {
  protocol : String
  username : String
  password : String
  hostname : String
  port : String
  pathname : String
  search : String
  hash : String
}

///|
fn whatwg(url : @mttp_core.Url) -> Whatwg raise PatternError {
  let protocol = canonicalize_protocol(url.scheme.unwrap_or(""))
  // A file: URL has neither credentials nor a port: WHATWG refuses one.
  if protocol == "file" && (url.userinfo is Some(_) || url.port is Some(_)) {
    raise Invalid("a file: URL with credentials or a port")
  }
  let special = special_schemes.contains(protocol)
  let (user, pass) = split_userinfo(url)
  {
    protocol,
    username: canonicalize_username(user),
    password: canonicalize_password(pass),
    hostname: match url.host {
      None | Some("") => ""
      // file: has no host when it names localhost.
      Some("localhost") if protocol == "file" => ""
      Some(h) if !special && !h.contains(":") => opaque_host(h)
      Some(_) => canonicalize_hostname(url_host(url.host))
    },
    port: match url.port {
      None => ""
      Some(p) => canonicalize_port(p.to_string(), Some(protocol))
    },
    pathname: if has_opaque_path(url) {
      canonicalize_opaque_pathname(url.path)
    } else if protocol == "file" {
      canonicalize_file_path(serialized_path(url))
    } else {
      canonicalize_pathname(serialized_path(url))
    },
    search: canonical_query(url.query.unwrap_or(""), special),
    hash: canonicalize_hash(url.fragment.unwrap_or("")),
  }
}

///|
/// "process a URLPatternInit": for a pattern (`pattern` true) the components
/// stay pattern strings; for a URL they are canonicalized.
fn process_init(
  init : PatternInit,
  pattern : Bool,
) -> PatternInit raise PatternError {
  let result = PatternInit::new()
  if init.base_url is Some(base) && base.scheme is None {
    raise Invalid("a base URL that is not absolute")
  }
  let base_text = (s : String) => if pattern { escape_pattern(s) } else { s }
  if init.base_url is Some(url) {
    let base = whatwg(url)
    if init.protocol is None {
      result.protocol = Some(base_text(base.protocol))
    }
    let given = [
      init.protocol is Some(_),
      init.hostname is Some(_),
      init.port is Some(_),
      init.pathname is Some(_),
      init.search is Some(_),
      init.hash is Some(_),
    ]
    let (user, pass) = (base.username, base.password)
    if !pattern && !given[0] && !given[1] && !given[2] && init.username is None {
      result.username = Some(user)
    }
    if !pattern &&
      !given[0] &&
      !given[1] &&
      !given[2] &&
      init.username is None &&
      init.password is None {
      result.password = Some(pass)
    }
    if !given[0] && !given[1] {
      result.hostname = Some(base_text(base.hostname))
    }
    if !given[0] && !given[1] && !given[2] {
      result.port = Some(base.port)
    }
    if !given[0] && !given[1] && !given[2] && !given[3] {
      result.pathname = Some(base_text(base.pathname))
    }
    if !given[0] && !given[1] && !given[2] && !given[3] && !given[4] {
      result.search = Some(base_text(base.search))
    }
    if !given.iter().any(g => g) {
      result.hash = Some(base_text(base.hash))
    }
  }
  if init.protocol is Some(p) {
    let stripped = if p.has_suffix(":") {
      p[:p.length() - 1].to_owned()
    } else {
      p
    }
    result.protocol = Some(
      if pattern {
        stripped
      } else {
        canonicalize_protocol(stripped)
      },
    )
  }
  if init.username is Some(u) {
    result.username = Some(if pattern { u } else { canonicalize_username(u) })
  }
  if init.password is Some(w) {
    result.password = Some(if pattern { w } else { canonicalize_password(w) })
  }
  if init.hostname is Some(h) {
    result.hostname = Some(if pattern { h } else { canonicalize_hostname(h) })
  }
  let protocol = result.protocol.unwrap_or("")
  if init.port is Some(port) {
    result.port = Some(
      if pattern {
        port
      } else {
        canonicalize_port(port, Some(protocol))
      },
    )
  }
  if init.pathname is Some(path) {
    let mut path = path
    if init.base_url is Some(base) &&
      !has_opaque_path(base) &&
      !is_absolute_pathname(path, pattern) {
      let base_path = base_text(whatwg(base).pathname)
      if base_path.rev_find("/") is Some(slash) {
        path = base_path[:slash + 1].to_owned() + path
      }
    }
    result.pathname = Some(
      if pattern {
        path
      } else if protocol == "" || special_schemes.contains(protocol) {
        canonicalize_pathname(path)
      } else {
        canonicalize_opaque_pathname(path)
      },
    )
  }
  if init.search is Some(s) {
    let stripped = if s.has_prefix("?") { s[1:].to_owned() } else { s }
    result.search = Some(
      if pattern {
        stripped
      } else {
        canonicalize_search(stripped)
      },
    )
  }
  if init.hash is Some(h) {
    let stripped = if h.has_prefix("#") { h[1:].to_owned() } else { h }
    result.hash = Some(
      if pattern {
        stripped
      } else {
        canonicalize_hash(stripped)
      },
    )
  }
  result
}

///|
/// `s` as a USVString: each lone surrogate becomes U+FFFD, as WebIDL
/// converts the standard's arguments.
fn usv(s : String) -> String {
  guard s.iter().any(c => c.to_int() >= 0xD800 && c.to_int() <= 0xDFFF) else {
    return s
  }
  String::from_iter(
    s
    .iter()
    .map(c => {
      if c.to_int() >= 0xD800 && c.to_int() <= 0xDFFF {
        '\u{FFFD}'
      } else {
        c
      }
    }),
  )
}

///|
fn usv_init(init : PatternInit) -> PatternInit {
  {
    protocol: init.protocol.map(usv),
    username: init.username.map(usv),
    password: init.password.map(usv),
    hostname: init.hostname.map(usv),
    port: init.port.map(usv),
    pathname: init.pathname.map(usv),
    search: init.search.map(usv),
    hash: init.hash.map(usv),
    base_url: init.base_url,
  }
}

///|
fn is_ipv6_pattern(input : String) -> Bool {
  let chars = input.to_array()
  guard chars.length() >= 2 else { return false }
  chars[0] == '[' || (chars[0] is ('{' | '\\') && chars[1] == '[')
}

///|
/// Makes a pattern of `init`'s components, as "create a URL pattern" does;
/// a component not given matches anything.
pub fn UrlPattern::new(init : PatternInit) -> UrlPattern raise PatternError {
  let p = process_init(usv_init(init), true)
  let protocol = p.protocol.unwrap_or("*")
  let mut port = p.port.unwrap_or("*")
  // Any decimal spelling of the default port, leading zeros too.
  if special_schemes.contains(protocol) &&
    port != "" &&
    port.iter().all(c => c.is_ascii_digit()) &&
    default_port(protocol) is Some(d) &&
    port.trim_start(chars="0") == d {
    port = ""
  }
  let protocol_component = compile_component(
    protocol, canonicalize_protocol, default_options,
  )
  let hostname = p.hostname.unwrap_or("*")
  let hostname_component = if is_ipv6_pattern(hostname) {
    compile_component(hostname, canonicalize_ipv6_hostname, hostname_options)
  } else {
    compile_component(hostname, canonicalize_hostname, hostname_options)
  }
  let special = special_schemes.iter().any(s => protocol_component.matches(s))
  let pathname = p.pathname.unwrap_or("*")
  let pathname_component = if special {
    compile_component(pathname, v => canonicalize_pathname(v), pathname_options)
  } else {
    compile_component(
      pathname,
      v => canonicalize_opaque_pathname(v),
      default_options,
    )
  }
  {
    protocol: protocol_component,
    username: compile_component(
      p.username.unwrap_or("*"),
      v => canonicalize_username(v),
      default_options,
    ),
    password: compile_component(
      p.password.unwrap_or("*"),
      v => canonicalize_password(v),
      default_options,
    ),
    hostname: hostname_component,
    port: compile_component(
      port,
      value => canonicalize_port(value, None),
      default_options,
    ),
    pathname: pathname_component,
    search: compile_component(
      p.search.unwrap_or("*"),
      v => canonicalize_search(v),
      default_options,
    ),
    hash: compile_component(
      p.hash.unwrap_or("*"),
      v => canonicalize_hash(v),
      default_options,
    ),
  }
}

///|
/// Makes a pattern of the string `input`, relative to `base` when given, as
/// `new URLPattern(input, base)` does. RFC 9842 makes a dictionary's
/// `match` this way, with the dictionary's URL as the base.
pub fn UrlPattern::parse(
  input : String,
  base? : @mttp_core.Url,
) -> UrlPattern raise PatternError {
  let init = parse_constructor_string(usv(input))
  guard base is Some(_) || init.protocol is Some(_) else {
    raise Invalid("a relative pattern without a base URL")
  }
  init.base_url = base
  UrlPattern::new(init)
}

///|
fn UrlPattern::test_components(
  self : UrlPattern,
  protocol : String,
  username : String,
  password : String,
  hostname : String,
  port : String,
  pathname : String,
  search : String,
  hash : String,
) -> Bool {
  self.protocol.matches(protocol) &&
  self.username.matches(username) &&
  self.password.matches(password) &&
  self.hostname.matches(hostname) &&
  self.port.matches(port) &&
  self.pathname.matches(pathname) &&
  self.search.matches(search) &&
  self.hash.matches(hash)
}

///|
/// Whether `url` matches, as `URLPattern.test(url)` does (`test` is a
/// keyword in MoonBit). Its components are read as WHATWG's URL parser
/// keeps them; `Url::parse` takes ASCII hosts only, so none needs IDNA.
pub fn UrlPattern::matches(self : UrlPattern, url : @mttp_core.Url) -> Bool {
  let w = whatwg(url) catch { _ => return false }
  self.test_components(
    w.protocol,
    w.username,
    w.password,
    w.hostname,
    w.port,
    w.pathname,
    w.search,
    w.hash,
  )
}

///|
/// Whether the URL `init` describes matches, as `URLPattern.test(init)`
/// does: its components are canonicalized first, and false comes back if
/// one cannot be. A component this package cannot canonicalize, a hostname
/// that needs IDNA, raises `Unsupported` rather than answer wrongly.
pub fn UrlPattern::matches_init(
  self : UrlPattern,
  init : PatternInit,
) -> Bool raise PatternError {
  let p = process_init(usv_init(init), false) catch {
    Unsupported(_) as e => raise e
    _ => return false
  }
  self.test_components(
    p.protocol.unwrap_or(""),
    p.username.unwrap_or(""),
    p.password.unwrap_or(""),
    p.hostname.unwrap_or(""),
    p.port.unwrap_or(""),
    p.pathname.unwrap_or(""),
    p.search.unwrap_or(""),
    p.hash.unwrap_or(""),
  )
}

///|
/// The pattern string of each component, in the order protocol, username,
/// password, hostname, port, pathname, search, hash: what the standard's
/// getters give.
pub fn UrlPattern::components(self : UrlPattern) -> FixedArray[String] {
  [
    self.protocol.pattern,
    self.username.pattern,
    self.password.pattern,
    self.hostname.pattern,
    self.port.pattern,
    self.pathname.pattern,
    self.search.pattern,
    self.hash.pattern,
  ]
}

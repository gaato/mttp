// web-platform-tests' urlpatterntestdata.json (see NOTICE) against
// gaato/mttp_core/urlpattern, checked as WPT's urlpatterntests.js checks
// it: the constructor throws or not, each component's pattern string, and
// test()'s result. exec()'s groups are not checked: the package matches
// without capturing. Cases fall outside it, and are counted, when they need
// what the package leaves out (regular expression groups, the ignoreCase
// option, IDNA hostnames) or a URL that `Url::parse`, an RFC 3986 parser,
// does not read as WHATWG's parser does.

///|

///|
priv suberror Skip {
  Skip(String)
}

///|
/// `text` as a URL, or Skip when `Url::parse`, an RFC 3986 parser, would
/// read it otherwise than WHATWG's: a special scheme without `//`, which
/// WHATWG reads as an authority, and a space, which WHATWG keeps in an
/// opaque path and `Url::parse` percent-encodes.
fn parse_url(text : String) -> @mttp_core.Url raise Skip {
  let url = @mttp_core.Url::parse(text) catch {
    _ => raise Skip("a URL Url::parse refuses")
  }
  if url.scheme is Some(s) &&
    ["http", "https", "ws", "wss", "ftp", "file"].contains(s) &&
    url.host is None {
    raise Skip("a special scheme without //")
  }
  if text.contains(" ") {
    raise Skip("a URL with a space")
  }
  // Url::parse percent-encodes characters RFC 3986 does not allow, which
  // WHATWG may keep, and resolves dot segments, which WHATWG does not in an
  // opaque path and reads otherwise when written %2e: a path, query or
  // fragment that is not, character for character, the text's is a
  // rewrite.
  let (before_hash, fragment) = match text.find("#") {
    Some(i) => (text[:i].to_owned(), Some(text[i + 1:].to_owned()))
    None => (text, None)
  }
  let (before_query, query) = match before_hash.find("?") {
    Some(i) =>
      (before_hash[:i].to_owned(), Some(before_hash[i + 1:].to_owned()))
    None => (before_hash, None)
  }
  let mut path = match before_query.find(":") {
    Some(i) if url.scheme is Some(_) => before_query[i + 1:].to_owned()
    _ => before_query
  }
  if path.has_prefix("//") {
    path = match path[2:].find("/") {
      Some(i) => path[2 + i:].to_owned()
      None => ""
    }
  }
  if url.path != path || url.query != query || url.fragment != fragment {
    raise Skip("a URL Url::parse rewrites")
  }
  url
}

///|
/// `input` against `base` as WHATWG's parser resolves it: None where that
/// fails, for a base that is not absolute, or one with an opaque path and a
/// reference that is not a fragment.
fn resolve(input : String, base : String) -> @mttp_core.Url? raise Skip {
  let b = @mttp_core.Url::parse(base) catch { _ => return None }
  guard b.scheme is Some(_) else { return None }
  let i = parse_url(input)
  if i.scheme is None &&
    b.host is None &&
    !b.path.has_prefix("/") &&
    !String::from_iter(input.iter().filter(c => !(c is ('\t' | '\n' | '\r'))))
    .trim_start(
      chars=String::from_iter((0).until(0x21).map(c => c.unsafe_to_char())),
    )
    .has_prefix("#") {
    return None
  }
  let b = parse_url(base)
  Some(b.resolve(i))
}

///|
fn init_of(json : Json) -> @up.PatternInit raise Skip {
  guard json is Object(o) else { raise Skip("an init that is not an object") }
  let get = (key : String) => {
    match o.get(key) {
      Some(String(s)) => Some(s)
      _ => None
    }
  }
  {
    protocol: get("protocol"),
    username: get("username"),
    password: get("password"),
    hostname: get("hostname"),
    port: get("port"),
    pathname: get("pathname"),
    search: get("search"),
    hash: get("hash"),
    base_url: match get("baseURL") {
      Some(text) => Some(parse_url(text))
      None => None
    },
  }
}

///|
let component_names : Array[String] = [
  "protocol", "username", "password", "hostname", "port", "pathname", "search", "hash",
]

///|
/// A component of `url` as the WHATWG URL getters give it, without the
/// separators the runner strips.
fn url_component(url : @mttp_core.Url, name : String) -> String {
  match name {
    "protocol" => url.scheme.unwrap_or("")
    "hostname" =>
      match url.host {
        Some(h) => if h.contains(":") { "[\{h}]" } else { h }
        None => ""
      }
    "port" =>
      match url.port {
        Some(p) => p.to_string()
        None => ""
      }
    "pathname" =>
      if url.path == "" && url.host is Some(_) {
        "/"
      } else {
        url.path
      }
    "search" => url.query.unwrap_or("")
    "hash" => url.fragment.unwrap_or("")
    _ => ""
  }
}

///|
/// The pattern string the runner expects for `name` when the case lists
/// none.
fn default_expected(
  entry : Map[String, Json],
  pattern : Array[Json],
  name : String,
) -> String raise Skip {
  if entry.get("exactly_empty_components") is Some(Array(empty)) &&
    empty.contains(Json::string(name)) {
    return ""
  }
  if pattern is [Object(o), ..] {
    if o.get(name) is Some(String(s)) && s != "" {
      return s
    }
    let earlier : Array[String] = match name {
      "hostname" => ["protocol"]
      "port" => ["protocol", "hostname"]
      "pathname" => ["protocol", "hostname", "port"]
      "search" => ["protocol", "hostname", "port", "pathname"]
      "hash" => ["protocol", "hostname", "port", "pathname", "search"]
      _ => []
    }
    if earlier.iter().any(c => o.contains(c)) {
      return "*"
    }
  }
  let base = match pattern {
    [Object(o), ..] =>
      match o.get("baseURL") {
        Some(String(b)) => Some(parse_url(b))
        _ => None
      }
    [_, String(b), ..] => Some(parse_url(b))
    _ => None
  }
  match base {
    Some(url) if name != "username" && name != "password" =>
      url_component(url, name)
    _ => "*"
  }
}

///|
fn construct(pattern : Array[Json]) -> @up.UrlPattern raise {
  match pattern {
    [] => @up.UrlPattern::new(@up.PatternInit::new())
    [String(s)] => @up.UrlPattern::parse(s)
    [String(s), String(b)] => @up.UrlPattern::parse(s, base=parse_url(b))
    [Object(_) as init] => @up.UrlPattern::new(init_of(init))
    // An init and a base URL: the constructor throws.
    [Object(_), String(_)] => raise @up.PatternError::Invalid("init and base")
    _ => raise Skip("the options argument (ignoreCase)")
  }
}

///|
fn run_test(p : @up.UrlPattern, inputs : Array[Json]) -> Bool raise Skip {
  let on_init = (init : @up.PatternInit) => {
    p.matches_init(init) catch {
      @up.Unsupported(why) => raise Skip(why)
      _ => false
    }
  }
  let on_url = (url : @mttp_core.Url) => p.matches(url)
  match inputs {
    [] => on_init(@up.PatternInit::new())
    [String(s)] => {
      let url = parse_url(s)
      // A relative URL without a base fails to parse: no match.
      url.scheme is Some(_) && on_url(url)
    }
    [String(s), String(b)] =>
      match resolve(s, b) {
        Some(url) => on_url(url)
        None => false
      }
    [Object(_) as init] => on_init(init_of(init))
    // test() throws for an init with a base URL string; count it as no match.
    [Object(_), String(_)] => false
    _ => raise Skip("inputs of another shape")
  }
}

///|
/// The case's outcome: None when it passes, or why it fails.
fn run_entry(entry : Map[String, Json]) -> String? raise Skip {
  guard entry.get("pattern") is Some(Array(pattern)) else {
    raise Skip("no pattern")
  }
  let expected_obj = entry.get("expected_obj")
  let built : Result[@up.UrlPattern, Error] = Ok(construct(pattern)) catch {
    e => Err(e)
  }
  if expected_obj is Some(String("error")) {
    return match built {
      Ok(_) => Some("constructed")
      Err(Skip(why)) => raise Skip(why)
      Err(_) => None
    }
  }
  let p = match built {
    Ok(p) => p
    Err(Skip(why)) => raise Skip(why)
    Err(@up.RegexpGroup) => raise Skip("a regular expression group")
    Err(@up.Unsupported(why)) => raise Skip(why)
    Err(e) => return Some("refused: \{e}")
  }
  let got = p.components()
  for i, name in component_names {
    let want = match expected_obj {
      Some(Object(o)) if o.get(name) is Some(String(s)) => s
      _ => default_expected(entry, pattern, name)
    }
    if got[i] != want {
      return Some("\{name} is \{got[i]}, not \{want}")
    }
  }
  let inputs = match entry.get("inputs") {
    Some(Array(inputs)) => inputs
    _ => return None
  }
  let want = match entry.get("expected_match") {
    Some(Null) | None => false
    Some(String("error")) => false
    Some(_) => true
  }
  let matched = run_test(p, inputs)
  if matched == want {
    None
  } else {
    Some("test() gave \{matched}")
  }
}

///|
test "urlpatterntestdata: each applicable case constructs, compiles and tests as WPT says" {
  guard @json.parse(urlpatterntestdata) is Array(rows) else {
    fail("bad vectors")
  }
  let failures = []
  let skips : Map[String, Int32] = Map([])
  for row in rows {
    guard row is Object(entry) else { fail("bad row") }
    let outcome : Result[String?, Error] = Ok(run_entry(entry)) catch {
      e => Err(e)
    }
    match outcome {
      Ok(None) => ()
      Ok(Some(why)) => failures.push("\{row.stringify()}: \{why}")
      Err(Skip(why)) => skips[why] = skips.get(why).unwrap_or(0) + 1
      Err(e) => failures.push("\{row.stringify()}: \{e}")
    }
  }
  if !failures.is_empty() {
    fail(
      "\{failures.length()} failed:\n\{failures[:failures.length().min(30)].join("\n")}",
    )
  }
  // What falls outside the package, pinned so a change shows.
  let pinned : Map[String, Int32] = {
    "a regular expression group": 22,
    "the options argument (ignoreCase)": 4,
    "an internationalized hostname needs IDNA": 3,
    "a URL with a space": 2,
    "a special scheme without //": 1,
  }
  assert_eq(skips, pinned)
  let skipped = pinned.values().fold(init=0, (a, b) => a + b)
  assert_eq((rows.length(), rows.length() - skipped), (369, 337))
}

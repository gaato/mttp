///|
fn url(text : String) -> @mttp_core.Url {
  @mttp_core.Url::parse(text) catch {
    e => abort("bad test URL \{text}: \{e}")
  }
}

///|
fn refusal(input : String, base? : @mttp_core.Url) -> @urlpattern.PatternError? {
  try {
    @urlpattern.UrlPattern::parse(input, base?) |> ignore
    None
  } catch {
    e => Some(e)
  }
}

///|
test "RFC 9842 matches: relative to the dictionary's URL, and same origin only" {
  let base = url("https://example.com/js/v1/app.js?q=1")
  let p = @urlpattern.UrlPattern::parse("/js/*/app.js", base~)
  assert_true(p.matches(url("https://example.com/js/v2/app.js")))
  assert_true(p.matches(url("https://example.com/js/v2/x/app.js?a=b")))
  assert_false(p.matches(url("https://example.com/css/v2/app.js")))
  assert_false(p.matches(url("http://example.com/js/v2/app.js")))
  assert_false(p.matches(url("https://example.com:8443/js/v2/app.js")))
  // A relative pathname is resolved against the base's directory.
  let rel = @urlpattern.UrlPattern::parse("app.*.js", base~)
  assert_eq(rel.components()[5], "/js/v1/app.*.js")
  assert_true(rel.matches(url("https://example.com/js/v1/app.min.js")))
  // An absolute pattern of another origin compiles but matches only there.
  let other = @urlpattern.UrlPattern::parse("https://cdn.example/*", base~)
  assert_false(other.matches(url("https://example.com/x")))
  assert_true(other.matches(url("https://cdn.example/x")))
}

///|
test "a search pattern and a hash pattern" {
  let base = url("https://example.com/")
  // After `*`, a `?` is the wildcard's modifier; after a character it
  // starts the search.
  let p = @urlpattern.UrlPattern::parse("/api/a?v=:version", base~)
  assert_true(p.matches(url("https://example.com/api/a?v=2")))
  assert_false(p.matches(url("https://example.com/api/a?v=")))
  assert_false(p.matches(url("https://example.com/api/a")))
  let modifier = @urlpattern.UrlPattern::parse("/api/*?v", base~)
  assert_eq(modifier.components()[5], "/api/*?v")
  let h = @urlpattern.UrlPattern::parse("/doc#top", base~)
  assert_true(h.matches(url("https://example.com/doc#top")))
  assert_false(h.matches(url("https://example.com/doc")))
  // A pathname alone leaves search and hash as wildcards.
  let path = @urlpattern.UrlPattern::parse("/doc", base~)
  assert_true(path.matches(url("https://example.com/doc?x#y")))
}

///|
test "named groups, groups in braces and their modifiers" {
  let p = (text : String) => {
    @urlpattern.UrlPattern::new(@urlpattern.PatternInit::new(pathname=text))
  }
  let m = (pattern : @urlpattern.UrlPattern, path : String) => {
    pattern.matches(url("https://h\{path}"))
  }
  let optional = p("/foo/:bar?")
  assert_true(m(optional, "/foo"))
  assert_true(m(optional, "/foo/x"))
  assert_false(m(optional, "/foo/x/y"))
  let some = p("/foo/:bar+")
  assert_false(m(some, "/foo"))
  assert_true(m(some, "/foo/a/b/c"))
  let any = p("/foo/:bar*")
  assert_true(m(any, "/foo"))
  assert_true(m(any, "/foo/a/b"))
  let braces = p("/book{s}?")
  assert_true(m(braces, "/book"))
  assert_true(m(braces, "/books"))
  assert_false(m(braces, "/bookss"))
  let repeated = p("/{a-:x}+/end")
  assert_true(m(repeated, "/a-1/end"))
  // The prefix repeats, the slash before the group does not.
  assert_true(m(repeated, "/a-1a-2/end"))
  assert_false(m(repeated, "/a-1/a-2/end"))
  assert_false(m(repeated, "/end"))
  assert_true(m(p("/\\*literal"), "/*literal"))
  assert_false(m(p("/\\*literal"), "/xliteral"))
}

///|
test "hostname and port patterns" {
  let p = @urlpattern.UrlPattern::parse("https://*.example.com/*")
  assert_true(p.matches(url("https://a.example.com/")))
  assert_true(p.matches(url("https://a.b.example.com/x")))
  assert_false(p.matches(url("https://example.com/")))
  // No port written is the default port; :* is any.
  assert_false(p.matches(url("https://a.example.com:8443/")))
  let any_port = @urlpattern.UrlPattern::parse("https://example.com:*/*")
  assert_true(any_port.matches(url("https://example.com:8443/")))
  assert_eq(
    @urlpattern.UrlPattern::parse("https://example.com:443/").components()[4],
    "",
  )
  // In a pattern, `:` starts a name: an IPv6 address escapes its colons.
  let ipv6 = @urlpattern.UrlPattern::parse("http://[\\:\\:1]/*")
  assert_true(ipv6.matches(url("http://[::1]/a")))
  assert_eq(
    @urlpattern.UrlPattern::parse("http://EXAMPLE.com/").components()[3],
    "example.com",
  )
  assert_eq(
    @urlpattern.UrlPattern::parse("http://0x7f.1/").components()[3],
    "127.0.0.1",
  )
}

///|
test "regular expression groups are refused, the standard's wildcards are not" {
  let base = url("https://example.com/")
  assert_eq(refusal("/:id(\\\\d+)", base~), Some(@urlpattern.RegexpGroup))
  assert_eq(refusal("/(foo|bar)", base~), Some(@urlpattern.RegexpGroup))
  assert_eq(refusal("/:x([^\\/]+?)", base~), None)
  assert_eq(refusal("/(.*)", base~), None)
}

///|
test "invalid patterns raise Invalid" {
  let base = url("https://example.com/")
  let invalid = (input : String) => {
    match refusal(input, base~) {
      Some(Invalid(_)) => true
      _ => false
    }
  }
  assert_true(invalid("/{foo"))
  assert_true(invalid("/:a/:a"))
  assert_true(invalid("/:"))
  assert_true(invalid("/foo\\"))
  // An escaped `:` is a character of the hostname, which a host refuses.
  let host = try {
    @urlpattern.UrlPattern::new(
      @urlpattern.PatternInit::new(hostname="bad\\:hostname"),
    )
    |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(host is Some(Invalid(_)))
  assert_true(refusal("/relative") is Some(Invalid(_)))
  assert_true(refusal("/x", base=url("/not-absolute")) is Some(Invalid(_)))
  assert_eq(
    refusal("https://café.example/"),
    Some(@urlpattern.Unsupported("an internationalized hostname needs IDNA")),
  )
}

///|
test "matching takes time linear in the input, whatever the pattern" {
  // A backtracking matcher takes exponential time on this pattern.
  let p = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(pathname="/*a*a*a*a*a*a*a*a*a*a*b"),
  )
  let path = StringBuilder()
  path.write_char('/')
  for _ in 0..<20000 {
    path.write_char('a')
  }
  assert_false(p.matches(url("https://h\{path.to_string()}")))
  path.write_char('b')
  assert_true(p.matches(url("https://h\{path.to_string()}")))
}

///|
test "matches_init canonicalizes, and refuses what needs IDNA" {
  let p = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(hostname="example.com", pathname="/a b"),
  )
  assert_eq(p.components()[5], "/a%20b")
  assert_true(
    p.matches_init(
      @urlpattern.PatternInit::new(
        protocol="https",
        hostname="EXAMPLE.com",
        pathname="/a b",
      ),
    ),
  )
  assert_false(
    p.matches_init(@urlpattern.PatternInit::new(hostname="exa mple.com")),
  )
  let refused = try {
    p.matches_init(@urlpattern.PatternInit::new(hostname="café.com")) |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(refused is Some(Unsupported(_)))
}

///|
test "a lone surrogate becomes U+FFFD, as a USVString" {
  let half = StringBuilder()
  half.write_char((0xD83D).unsafe_to_char())
  let p = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(pathname="/\{half.to_string()}"),
  )
  assert_eq(p.components()[5], "/%EF%BF%BD")
}

///|
test "a Url is read as WHATWG's parser keeps it" {
  let p = (text : String) => @urlpattern.UrlPattern::parse(text)
  assert_true(p("http://127.0.0.1/*").matches(url("http://0x7f.1/")))
  assert_true(p("https://h/b").matches(url("https://h/a/%2e%2e/b")))
  assert_true(p("https://h/?a%27b").matches(url("https://h/?a'b")))
  // A base URL's components are read the same way.
  let init = @urlpattern.PatternInit::new(base_url=url("http://0x7f.1/a"))
  assert_true(p("http://127.0.0.1/a").matches_init(init))
}

///|
test "an opaque path ends at ? and #, and default ports have any spelling" {
  let data = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(protocol="data", pathname="abc\\?x"),
  )
  assert_eq(data.components()[5], "abc")
  let abc = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(protocol="data", pathname="abc"),
  )
  assert_true(
    abc.matches_init(
      @urlpattern.PatternInit::new(protocol="data", pathname="abc?x"),
    ),
  )
  let port = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(protocol="https", port="0443"),
  )
  assert_eq(port.components()[4], "")
  assert_true(port.matches(url("https://h/")))
  let spaced = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(protocol=" https"),
  )
  assert_eq(spaced.components()[0], "https")
}

///|
test "non-special hosts stay opaque, and file: URLs are read as WHATWG does" {
  let foo = @urlpattern.UrlPattern::parse("foo://0x7f.1/a")
  assert_false(foo.matches(url("foo://0x7f.1/a")))
  let file = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(
      protocol="file",
      hostname="",
      pathname="/tmp/a",
    ),
  )
  assert_true(file.matches(url("file://localhost/tmp/a")))
  let drive = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(protocol="file", pathname="/C\\:/x"),
  )
  assert_true(drive.matches(url("file:///C|/x")))
}

///|
test "an opaque path keeps a space before ? or #, and a protocol ends at :" {
  let data = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(protocol="data", pathname="abc \\?x"),
  )
  assert_eq(data.components()[5], "abc%20")
  assert_true(
    data.matches_init(
      @urlpattern.PatternInit::new(protocol="data", pathname="abc #x"),
    ),
  )
  let colon = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(protocol="data\\:foo"),
  )
  assert_eq(colon.components()[0], "data")
  assert_true(
    @urlpattern.UrlPattern::new(@urlpattern.PatternInit::new(protocol="data")).matches_init(
      @urlpattern.PatternInit::new(protocol="data:foo"),
    ),
  )
}

///|
test "a protocol must leave a URL that parses, and file: URLs keep their drive" {
  let bad = try {
    @urlpattern.UrlPattern::new(
      @urlpattern.PatternInit::new(protocol="https\\:#"),
    )
    |> ignore
    None
  } catch {
    e => Some(e)
  }
  assert_true(bad is Some(Invalid(_)))
  let parse = (text : String) => {
    Some(@urlpattern.UrlPattern::parse(text)) catch {
      _ => None
    }
  }
  assert_true(parse("https{\\:[bad}://example.com/*") is None)
  assert_true(parse("https{\\:a b}://example.com/*") is None)
  // The slash ends the port before the dummy URL's own "://".
  assert_true(parse("https{\\:a\\:99999/}://example.com/*") is None)
  assert_true(parse("https{\\:a\\:65535/}://example.com/*") is Some(_))
  assert_true(parse("file{\\://[bad/}://example.com/*") is None)
  assert_true(parse("foo{\\://h\\:99999/}://example.com/*") is None)
  assert_true(parse("foo{\\://h\\:99/}://example.com/*") is Some(_))
  let odd = parse("https{\\:@a/}://example.com/*").unwrap()
  assert_true(odd.matches(url("https://example.com/x")))
  let https = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(protocol="https"),
  )
  assert_false(
    https.matches_init(@urlpattern.PatternInit::new(protocol="https:#")),
  )
  let drive = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(protocol="file", pathname="/C\\:/x"),
  )
  assert_true(drive.matches(url("file:///C:/%2e%2e/x")))
  let file = @urlpattern.UrlPattern::new(
    @urlpattern.PatternInit::new(protocol="file"),
  )
  assert_false(file.matches(url("file://user@h/x")))
  assert_false(file.matches(url("file://h:80/x")))
  assert_true(file.matches(url("file://h/x")))
}

///|
test "PatternError shows its reason" {
  assert_eq(@urlpattern.Invalid("x").to_string(), "invalid URL pattern: x")
  assert_eq(
    @urlpattern.RegexpGroup.to_string(),
    "URL pattern with a regular expression",
  )
  assert_eq(
    @urlpattern.Unsupported("y").to_string(),
    "unsupported URL pattern: y",
  )
}

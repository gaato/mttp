///|
fn set_cookies(values : Array[String]) -> @model.Headers {
  @model.Headers::of(values.map(value => ("Set-Cookie", value)))
}

///|
fn names(jar : @cookie.CookieJar) -> Array[String] {
  jar.iter().map(cookie => cookie.name).collect()
}

///|
test "store reads every Set-Cookie of a response and header_for uses the clock" {
  let clock = @fake.FakeClock::new(start_unix_ms=1_000_000L)
  let jar = @cookie.CookieJar::new(clock)
  let mut headers = set_cookies(["a=1; Max-Age=60", "b=2; Path=/docs"])
  headers = headers.add("Content-Type", "text/plain")
  jar.store(headers, "https://example.com/login")
  assert_eq(jar.length(), 2)
  assert_eq(jar.header_for("https://example.com/docs/x"), Some("b=2; a=1"))
  assert_eq(jar.header_for("https://example.com/"), Some("a=1"))
  assert_eq(jar.header_for("https://other.com/"), None)
  clock.advance(60_000)
  assert_eq(jar.header_for("https://example.com/"), None)
  assert_eq(jar.length(), 1)
  let cookie = jar.iter().collect()[0]
  assert_eq(cookie.name, "b")
  assert_eq(cookie.path, "/docs")
  assert_eq(cookie.creation_ms, 1_000_000L)
  assert_eq(cookie.last_access_ms, 1_000_000L)
}

///|
test "a URL without a host stores and sends nothing" {
  let jar = @cookie.CookieJar::new(@fake.FakeClock::new())
  jar.store(set_cookies(["a=1"]), "not a url")
  jar.store(set_cookies(["a=1"]), "file:///etc/hosts")
  jar.store(set_cookies(["a=1"]), "http://b\u{fc}cher.example/")
  assert_eq(jar.length(), 0)
  jar.store(set_cookies(["a=1"]), "http://a.com/")
  assert_eq(jar.header_for("/relative"), None)
  assert_eq(jar.header_for("http://a.com/"), Some("a=1"))
}

///|
test "clear, clear_domain, clear_session and remove_expired remove what they name" {
  let clock = @fake.FakeClock::new()
  let jar = @cookie.CookieJar::new(clock)
  jar.store(set_cookies(["root=1; Domain=example.com"]), "http://example.com/")
  jar.store(set_cookies(["www=1"]), "http://www.example.com/")
  jar.store(set_cookies(["short=1; Max-Age=1"]), "http://other.com/")
  jar.store(set_cookies(["long=1; Max-Age=100"]), "http://other.com/")
  jar.store(set_cookies(["bad=1"]), "http://badexample.com/")
  jar.clear_domain("Example.com")
  assert_eq(names(jar), ["short", "long", "bad"])
  clock.advance(1000)
  jar.remove_expired()
  assert_eq(names(jar), ["long", "bad"])
  jar.clear_session()
  assert_eq(names(jar), ["long"])
  assert_eq(jar.length(), 1)
  jar.clear()
  assert_eq(jar.length(), 0)
  assert_eq(jar.header_for("http://other.com/"), None)
}

///|
test "attach adds the jar's Cookie header unless the request has one" {
  let jar = @cookie.CookieJar::new(@fake.FakeClock::new())
  jar.store(set_cookies(["sid=1"]), "https://a.example/")
  let plain = @model.Request::get("https://a.example/x")
  let attached = jar.attach(plain)
  assert_eq(attached.headers.get_all("cookie"), ["sid=1"])
  assert_eq(plain.headers.length(), 0)
  let explicit = plain.header("COOKIE", "mine=2")
  assert_eq(jar.attach(explicit).headers.get_all("cookie"), ["mine=2"])
  let elsewhere = @model.Request::get("https://b.example/")
  assert_eq(jar.attach(elsewhere).headers.length(), 0)
  assert_eq(jar.attach(@model.Request::get("/relative")).headers.length(), 0)
}

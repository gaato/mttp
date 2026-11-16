///|
/// A stand-in for SHA-256: 32 bytes that depend on every input byte. The
/// store only compares and sends what it is given.
fn fake_sha256(data : BytesView) -> Bytes {
  let out = FixedArray::make(32, b'\x00')
  let mut h = 2166136261U
  for i, b in data {
    h = (h ^ b.to_uint()) * 16777619U
    out[i % 32] = out[i % 32] ^ (h & 0xFFU).to_byte()
  }
  out[0] = out[0] ^ (data.length() & 0xFF).to_byte()
  Bytes::from_array(out)
}

///|
fn url(text : String) -> @mttp_core.Url {
  @mttp_core.Url::parse(text) catch {
    e => abort("bad test URL \{text}: \{e}")
  }
}

///|
fn response(
  use_as_dictionary : String,
  cc~ : String = "max-age=3600",
) -> @mttp_core.Headers {
  @mttp_core.Headers::of([
    ("use-as-dictionary", use_as_dictionary),
    ("cache-control", cc),
  ])
}

///|
fn store(
  clock : @sim.FakeClock,
  max_entries~ : Int32 = 64,
  max_dictionary_bytes~ : Int32 = 4 * 1024 * 1024,
  max_total_bytes~ : Int32 = 32 * 1024 * 1024,
) -> @dictionary.DictionaryStore {
  @dictionary.DictionaryStore::new(
    sha256=fake_sha256,
    clock~,
    max_entries~,
    max_dictionary_bytes~,
    max_total_bytes~,
  )
}

///|
test "Use-As-Dictionary: match, match-dest, id and type, as section 2.1 says" {
  let parse = (v : String) => @dictionary.UseAsDictionary::parse([v])
  assert_eq(
    parse(
      "match=\"/app/*/main.js\", match-dest=(\"document\" \"script\"), id=\"d-1\"",
    ),
    Some({
      match_: "/app/*/main.js",
      match_dest: ["document", "script"],
      id: "d-1",
    }),
  )
  assert_eq(
    parse("match=\"/a\", type=raw"),
    Some({ match_: "/a", match_dest: [], id: "", }),
  )
  // An unknown type must not be used; so must a field without a match.
  assert_eq(parse("match=\"/a\", type=shared-brotli"), None)
  assert_eq(parse("id=\"x\""), None)
  assert_eq(parse("match=/a"), None)
  assert_eq(parse("match=\"/a\", match-dest=\"document\""), None)
  assert_eq(parse("match=\"/a\", match-dest=(document)"), None)
  assert_eq(parse("match=a"), None)
  assert_eq(parse("match=\"/a\", id=1"), None)
  assert_eq(parse("match=\"/a\", type=\"raw\""), None)
  assert_eq(parse("match=\"/a"), None)
  // Unknown keys are ignored.
  assert_eq(
    parse("match=\"/a\", future=?1"),
    Some({ match_: "/a", match_dest: [], id: "", }),
  )
}

///|
test "Use-As-Dictionary: the field, the match and the id are bounded" {
  let long = (n : Int32) => String::make(n, 'a')
  assert_true(
    @dictionary.UseAsDictionary::parse(["match=\"/\{long(1023)}\""]) is Some(_),
  )
  assert_eq(
    @dictionary.UseAsDictionary::parse(["match=\"/\{long(1024)}\""]),
    None,
  )
  assert_true(
    @dictionary.UseAsDictionary::parse(["match=\"/\", id=\"\{long(1024)}\""])
    is Some(_),
  )
  assert_eq(
    @dictionary.UseAsDictionary::parse(["match=\"/\", id=\"\{long(1025)}\""]),
    None,
  )
  assert_eq(
    @dictionary.UseAsDictionary::parse(["match=\"/\", x=\"\{long(8200)}\""]),
    None,
  )
}

///|
test "Use-As-Dictionary: written back as a field value" {
  let d : @dictionary.UseAsDictionary = {
    match_: "/p/*",
    match_dest: ["document"],
    id: "v\"1",
  }
  assert_eq(
    d.to_header(),
    Some("match=\"/p/*\", match-dest=(\"document\"), id=\"v\\\"1\""),
  )
  assert_eq(
    @dictionary.UseAsDictionary::parse([d.to_header().unwrap()]),
    Some(d),
  )
  assert_eq(
    { ..d, match_dest: [], id: "", }.to_header(),
    Some("match=\"/p/*\""),
  )
  assert_eq({ ..d, match_: "/é", }.to_header(), None)
  assert_eq({ ..d, id: String::make(1025, 'i'), }.to_header(), None)
  assert_eq({ ..d, match_: "/" + String::make(1024, 'm'), }.to_header(), None)
  assert_eq({ ..d, match_dest: Array::make(1000, "script"), }.to_header(), None)
}

///|
test "a fresh response with Use-As-Dictionary from a trustworthy URL is stored" {
  let clock = @sim.FakeClock::new(start_unix_ms=1_000_000L)
  let s = store(clock)
  let body = b"dictionary bytes"
  assert_true(
    s.offer(
      url("https://example.com/d.dat"),
      response("match=\"/app/*\""),
      body,
      request_time_ms=1_000_000L,
    ),
  )
  assert_eq(s.size(), (1, body.length().to_int64()))
  let d = s.select(url("https://example.com/app/x.js")).unwrap()
  assert_eq(d.content, body)
  assert_eq(d.hash, fake_sha256(body))
  assert_eq(
    d.available_dictionary(),
    ":" + @base64.encode(fake_sha256(body)) + ":",
  )
  assert_eq(d.dictionary_id(), None)
  assert_true(s.find(fake_sha256(body)) is Some(_))
  assert_true(s.find(fake_sha256(b"other")) is None)
  // Not for another path, another origin, or plain http.
  assert_true(s.select(url("https://example.com/other")) is None)
  assert_true(s.select(url("https://example.org/app/x.js")) is None)
  assert_true(s.select(url("http://example.com/app/x.js")) is None)
}

///|
test "responses that are not stored" {
  let clock = @sim.FakeClock::new(start_unix_ms=1_000_000L)
  let s = store(clock, max_dictionary_bytes=8)
  let offer = (u : String, h : @mttp_core.Headers, body : Bytes) => {
    s.offer(url(u), h, body, request_time_ms=1_000_000L)
  }
  let ok = response("match=\"/*\"")
  assert_false(offer("http://example.com/d", ok, b"x"))
  assert_false(
    offer(
      "https://example.com/d",
      @mttp_core.Headers::of([("cache-control", "max-age=60")]),
      b"x",
    ),
  )
  assert_false(
    offer("https://example.com/d", response("match=\"/:v(\\\\d+)\""), b"x"),
  )
  assert_false(
    offer(
      "https://example.com/d",
      response("match=\"/*\"", cc="no-store, max-age=60"),
      b"x",
    ),
  )
  assert_false(
    offer(
      "https://example.com/d",
      response("match=\"/*\"", cc="no-cache"),
      b"x",
    ),
  )
  // Fresh but no-cache: it would need validating before each use.
  assert_false(
    offer(
      "https://example.com/d",
      response("match=\"/*\"", cc="no-cache, max-age=3600"),
      b"x",
    ),
  )
  assert_false(
    offer(
      "https://example.com/d",
      response("match=\"/*\"", cc="max-age=0"),
      b"x",
    ),
  )
  assert_false(offer("https://example.com/d", ok, b"123456789"))
  assert_eq(s.size(), (0, 0L))
  // Loopback over http is trustworthy.
  assert_true(offer("http://localhost:8080/d", ok, b"x"))
  assert_true(offer("http://127.0.0.1/d", ok, b"x"))
  assert_true(offer("http://[::1]/d", ok, b"x"))
  // A stale response within stale-while-revalidate may be stored.
  let swr = @mttp_core.Headers::of([
    ("use-as-dictionary", "match=\"/*\""),
    ("cache-control", "max-age=10, stale-while-revalidate=60"),
    ("age", "20"),
  ])
  assert_true(offer("https://example.com/swr", swr, b"y"))
}

///|
test "is_trustworthy: https, and http to a loopback host" {
  assert_true(@dictionary.is_trustworthy(url("https://example.com/")))
  assert_true(@dictionary.is_trustworthy(url("http://app.localhost/")))
  assert_false(@dictionary.is_trustworthy(url("http://example.com/")))
  assert_false(@dictionary.is_trustworthy(url("wss://example.com/")))
  assert_false(@dictionary.is_trustworthy(url("/relative")))
  // A DNS name that only starts like a loopback address is not one.
  assert_false(@dictionary.is_trustworthy(url("http://127.attacker.example/")))
  assert_false(@dictionary.is_trustworthy(url("http://127.1/")))
  assert_false(@dictionary.is_trustworthy(url("http://127.0.0.256/")))
  assert_false(@dictionary.is_trustworthy(url("http://127.0.0.1x/")))
  assert_true(@dictionary.is_trustworthy(url("http://127.255.0.9/")))
  assert_true(@dictionary.is_trustworthy(url("http://app.localhost./")))
  assert_true(@dictionary.is_trustworthy(url("http://LOCALHOST/")))
}

///|
test "selection: a named destination, then the longest match, then the most recent" {
  let clock = @sim.FakeClock::new(start_unix_ms=1_000_000L)
  let s = store(clock)
  let offer = (path : String, uad : String) => {
    clock.advance(1000)
    s.offer(
      url("https://e.com\{path}"),
      response(uad),
      @utf8.encode("bytes of \{path}"),
      request_time_ms=1_000_000L,
    )
    |> ignore
  }
  offer("/short", "match=\"/a/*\"")
  offer("/long", "match=\"/a/b/*\"")
  offer("/dest", "match=\"/a/*\", match-dest=(\"script\")")
  offer("/style", "match=\"/a/b/c/*\", match-dest=(\"style\")")
  let pick = (path : String, dest : String?) => {
    s.select(url("https://e.com\{path}"), dest?).map(d => d.url.path)
  }
  // A client without destinations: every match-dest matches; longest wins.
  assert_eq(pick("/a/b/c/x", None), Some("/style"))
  assert_eq(pick("/a/b/x", None), Some("/long"))
  // With one, a dictionary that names it comes first.
  assert_eq(pick("/a/b/x", Some("script")), Some("/dest"))
  // A match-dest that does not include it is skipped.
  assert_eq(pick("/a/b/c/x", Some("document")), Some("/long"))
  // Equal length and destination: the most recently stored.
  offer("/short2", "match=\"/a/*\"")
  assert_eq(pick("/a/x", Some("document")), Some("/short2"))
}

///|
test "a dictionary expires, unless stale-while-revalidate still covers it" {
  let clock = @sim.FakeClock::new(start_unix_ms=1_000_000L)
  let s = store(clock)
  assert_true(
    s.offer(
      url("https://e.com/d"),
      response("match=\"/*\"", cc="max-age=10, stale-while-revalidate=5"),
      b"x",
      request_time_ms=1_000_000L,
    ),
  )
  clock.advance(14_000)
  assert_true(s.select(url("https://e.com/p")) is Some(_))
  clock.advance(2_000)
  assert_true(s.select(url("https://e.com/p")) is None)
  assert_eq(s.size(), (0, 0L))
}

///|
test "partitions keep dictionaries apart, and clear empties them" {
  let clock = @sim.FakeClock::new(start_unix_ms=1_000_000L)
  let s = store(clock)
  let ok = response("match=\"/*\", id=\"site-a\"")
  assert_true(
    s.offer(
      url("https://e.com/d"),
      ok,
      b"aa",
      request_time_ms=1_000_000L,
      partition="a",
    ),
  )
  assert_true(
    s.offer(
      url("https://e.com/d"),
      ok,
      b"bbb",
      request_time_ms=1_000_000L,
      partition="b",
    ),
  )
  assert_eq(
    s.select(url("https://e.com/x"), partition="a").map(d => d.content),
    Some(b"aa"),
  )
  assert_eq(
    s.select(url("https://e.com/x"), partition="a").bind(d => d.dictionary_id()),
    Some("\"site-a\""),
  )
  assert_true(s.select(url("https://e.com/x")) is None)
  assert_true(s.find(fake_sha256(b"aa"), partition="b") is None)
  s.clear(partition="a")
  assert_eq(s.size(), (1, 3L))
  s.clear()
  assert_eq(s.size(), (0, 0L))
}

///|
test "the caps: the same URL replaces, the oldest go first" {
  let clock = @sim.FakeClock::new(start_unix_ms=1_000_000L)
  let s = store(clock, max_entries=2, max_total_bytes=10)
  let offer = (path : String, body : Bytes) => {
    s.offer(
      url("https://e.com\{path}"),
      response("match=\"\{path}/*\""),
      body,
      request_time_ms=1_000_000L,
    )
  }
  assert_true(offer("/1", b"1111"))
  assert_true(offer("/1", b"111"))
  assert_eq(s.size(), (1, 3L))
  assert_true(offer("/2", b"2222"))
  assert_true(offer("/3", b"33"))
  assert_eq(s.size(), (2, 6L))
  assert_true(s.select(url("https://e.com/1/x")) is None)
  // Past the byte cap, the oldest go until the new one fits.
  assert_true(offer("/4", b"4444444444"))
  assert_eq(s.size(), (1, 10L))
  assert_false(offer("/5", b"55555555555"))
  let none = store(clock, max_entries=-1)
  assert_false(
    none.offer(
      url("https://e.com/d"),
      response("match=\"/*\""),
      b"x",
      request_time_ms=1_000_000L,
    ),
  )
}

///|
test "method tokens parse roundtrip and classify idempotence" {
  for
    (name, idem) in [
      ("GET", true),
      ("HEAD", true),
      ("POST", false),
      ("PUT", true),
      ("DELETE", true),
      ("CONNECT", false),
      ("OPTIONS", true),
      ("TRACE", true),
      ("PATCH", false),
      ("CUSTOM", false),
    ] {
    let meth = @mttp_core.Method::parse(name)
    assert_eq(meth.to_string(), name)
    assert_eq("\{meth}", name)
    assert_eq(meth.is_idempotent(), idem)
    assert_eq(
      @mttp_core.is_idempotent(@mttp_core.Request::new(meth, "/")),
      idem,
    )
  }
  assert_false(
    @mttp_core.is_idempotent(
      @mttp_core.Request::post("/").header("Idempotency-Key", "key"),
    ),
  )
  assert_true(
    @mttp_core.is_idempotent(
      @mttp_core.Request::post("/").attribute(@mttp_core.replay_safe, true),
    ),
  )
  assert_false(
    @mttp_core.is_idempotent(
      @mttp_core.Request::post("/").attribute(@mttp_core.replay_safe, false),
    ),
  )
}

///|
test "request builders preserve their source" {
  let source = @mttp_core.Request::get("https://example.test/items")
  let changed = source
    .header("x", "1")
    .set_header("x", "2")
    .bearer("token")
    .query("q", "a b")
  assert_eq(source.headers.length(), 0)
  assert_eq(source.body, Empty)
  assert_eq(source.body.length(), Some(0))
  assert_eq(source.body.as_bytes(), Some(b""))
  assert_true(source.body.is_replayable())
  assert_eq(changed.headers.get("x"), Some("2"))
  assert_eq(changed.headers.get("authorization"), Some("Bearer token"))
  assert_eq(changed.url, "https://example.test/items?q=a%20b")
  assert_eq(changed.head().meth, Get)
  assert_eq(@mttp_core.Request::put("/").head().meth, Put)
  assert_eq(@mttp_core.Request::delete("/").head().meth, Delete)
  source.validate()
  let invalid = @mttp_core.Request::new(Other("bad method"), "/")
  let refused = try {
    invalid.validate()
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}

///|
test "response metadata success classes and conventional phrases" {
  let response = @mttp_core.Response::new(
    201,
    headers=@mttp_core.Headers::of([("x", "1")]),
    body=Bytes(b"created"),
  )
  assert_eq(response.head().status, 201)
  assert_eq(response.head().headers.get("x"), Some("1"))
  response.close()
  assert_false(@mttp_core.is_success(199))
  assert_true(@mttp_core.is_success(200))
  assert_true(@mttp_core.is_success(299))
  assert_false(@mttp_core.is_success(300))
  for
    (status, phrase) in [
      (100, "Continue"),
      (101, "Switching Protocols"),
      (200, "OK"),
      (201, "Created"),
      (202, "Accepted"),
      (203, "Non-Authoritative Information"),
      (204, "No Content"),
      (205, "Reset Content"),
      (206, "Partial Content"),
      (300, "Multiple Choices"),
      (301, "Moved Permanently"),
      (302, "Found"),
      (303, "See Other"),
      (304, "Not Modified"),
      (305, "Use Proxy"),
      (307, "Temporary Redirect"),
      (308, "Permanent Redirect"),
      (400, "Bad Request"),
      (401, "Unauthorized"),
      (402, "Payment Required"),
      (403, "Forbidden"),
      (404, "Not Found"),
      (405, "Method Not Allowed"),
      (406, "Not Acceptable"),
      (407, "Proxy Authentication Required"),
      (408, "Request Timeout"),
      (409, "Conflict"),
      (410, "Gone"),
      (411, "Length Required"),
      (412, "Precondition Failed"),
      (413, "Content Too Large"),
      (414, "URI Too Long"),
      (415, "Unsupported Media Type"),
      (416, "Range Not Satisfiable"),
      (417, "Expectation Failed"),
      (421, "Misdirected Request"),
      (422, "Unprocessable Content"),
      (426, "Upgrade Required"),
      (428, "Precondition Required"),
      (429, "Too Many Requests"),
      (431, "Request Header Fields Too Large"),
      (451, "Unavailable For Legal Reasons"),
      (500, "Internal Server Error"),
      (501, "Not Implemented"),
      (502, "Bad Gateway"),
      (503, "Service Unavailable"),
      (504, "Gateway Timeout"),
      (505, "HTTP Version Not Supported"),
      (511, "Network Authentication Required"),
      (599, ""),
    ] {
    assert_eq(@mttp_core.reason_phrase(status), phrase)
  }
}

///|
test "prefix joining and path codecs" {
  assert_eq(
    @mttp_core.append_query("/a#fragment?x", "q", "a b"),
    "/a?q=a%20b#fragment?x",
  )
  assert_eq(
    @mttp_core.append_query("/a?x=1#fragment", "q", "2"),
    "/a?x=1&q=2#fragment",
  )
  for
    (base, target, expected) in [
      ("", "/x", "/x"),
      ("https://h/v1/", "", "https://h/v1"),
      ("https://h/v1", "/items", "https://h/v1/items"),
      ("https://h/v1/", "items", "https://h/v1/items"),
      ("https://h/v1", "?x=1", "https://h/v1?x=1"),
      ("https://h", "https://other/x", "https://other/x"),
      ("https://h", "http://other/x", "http://other/x"),
    ] {
    assert_eq(@mttp_core.join_url(base, target), expected)
  }
  assert_eq(@mttp_core.encode_path([]), "/")
  assert_eq(
    @mttp_core.encode_path(["a/b", "日本"]),
    "/a%2Fb/%E6%97%A5%E6%9C%AC",
  )
  assert_eq(
    @mttp_core.Url::parse("/a%2Fb/%E6%97%A5%E6%9C%AC").path_segments(),
    ["a/b", "日本"],
  )
  assert_eq(@mttp_core.Url::parse("").path_segments(), [])
  assert_eq(@mttp_core.Url::parse("/").path_segments(), [])
  assert_eq(@mttp_core.Url::parse("a/b").path_segments(), ["a", "b"])
  let refused = try {
    let _ = @mttp_core.percent_decode("%xx")
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}

///|
test "unsent classification is conservative" {
  let cases : Array[(@mttp_core.Kind, @mttp_core.Phase, Bool)] = [
    (Connect, Dial, true),
    (Proxy(status=407), Head, true),
    (Timeout(ms=1), Pool, true),
    (Timeout(ms=1), Dial, true),
    (Timeout(ms=1), Head, false),
    (Network, Write, false),
    (Network, Dial, true),
    (Protocol, Head, false),
    (Invalid, Pool, true),
    (Unreplayable, Pool, true),
    (Proxy(status=502), Unknown, true),
    (Closed, Unknown, false),
    (Closed, Pool, true),
    (Closed, Head, false),
  ]
  for (kind, phase, unsent) in cases {
    let error = @mttp_core.TransportError(kind~, phase~, detail="test failure")
    assert_eq(error.is_unsent(), unsent)
    assert_true(error.message().has_suffix(": test failure"))
  }
}

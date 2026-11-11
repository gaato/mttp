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
    let meth = @mttp.Method::parse(name)
    assert_eq(meth.to_string(), name)
    assert_eq("\{meth}", name)
    assert_eq(meth.is_idempotent(), idem)
    assert_eq(@mttp.is_idempotent(@mttp.Request::new(meth, "/")), idem)
  }
  assert_false(
    @mttp.is_idempotent(
      @mttp.Request::post("/").header("Idempotency-Key", "key"),
    ),
  )
  assert_true(
    @mttp.is_idempotent(
      @mttp.Request::post("/").attribute(@mttp.replay_safe, true),
    ),
  )
  assert_false(
    @mttp.is_idempotent(
      @mttp.Request::post("/").attribute(@mttp.replay_safe, false),
    ),
  )
}

///|
test "request builders preserve their source" {
  let source = @mttp.Request::get("https://example.test/items")
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
  assert_eq(@mttp.Request::put("/").head().meth, Put)
  assert_eq(@mttp.Request::delete("/").head().meth, Delete)
  source.validate()
  let invalid = @mttp.Request::new(Other("bad method"), "/")
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
  let response = @mttp.Response::new(
    201,
    headers=@mttp.Headers::of([("x", "1")]),
    body=Bytes(b"created"),
  )
  assert_eq(response.head().status, 201)
  assert_eq(response.head().headers.get("x"), Some("1"))
  response.close()
  assert_false(@mttp.is_success(199))
  assert_true(@mttp.is_success(200))
  assert_true(@mttp.is_success(299))
  assert_false(@mttp.is_success(300))
  for
    (status, phrase) in [
      (200, "OK"),
      (201, "Created"),
      (202, "Accepted"),
      (204, "No Content"),
      (400, "Bad Request"),
      (401, "Unauthorized"),
      (403, "Forbidden"),
      (404, "Not Found"),
      (405, "Method Not Allowed"),
      (406, "Not Acceptable"),
      (408, "Request Timeout"),
      (413, "Content Too Large"),
      (415, "Unsupported Media Type"),
      (422, "Unprocessable Content"),
      (431, "Request Header Fields Too Large"),
      (500, "Internal Server Error"),
      (504, "Gateway Timeout"),
      (599, ""),
    ] {
    assert_eq(@mttp.reason_phrase(status), phrase)
  }
}

///|
test "prefix joining and path codecs" {
  assert_eq(
    @mttp.append_query("/a#fragment?x", "q", "a b"),
    "/a?q=a%20b#fragment?x",
  )
  assert_eq(
    @mttp.append_query("/a?x=1#fragment", "q", "2"),
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
    assert_eq(@mttp.join_url(base, target), expected)
  }
  assert_eq(@mttp.encode_path([]), "/")
  assert_eq(@mttp.encode_path(["a/b", "日本"]), "/a%2Fb/%E6%97%A5%E6%9C%AC")
  assert_eq(@mttp.Url::parse("/a%2Fb/%E6%97%A5%E6%9C%AC").path_segments(), [
    "a/b", "日本",
  ])
  assert_eq(@mttp.Url::parse("").path_segments(), [])
  assert_eq(@mttp.Url::parse("/").path_segments(), [])
  assert_eq(@mttp.Url::parse("a/b").path_segments(), ["a", "b"])
  let refused = try {
    let _ = @mttp.percent_decode("%xx")
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}

///|
test "unsent classification is conservative" {
  let cases : Array[(@mttp.Kind, @mttp.Phase, Bool)] = [
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
    let error = @mttp.TransportError(kind~, phase~, detail="test failure")
    assert_eq(error.is_unsent(), unsent)
    assert_true(error.message().has_suffix(": test failure"))
  }
}

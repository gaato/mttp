///|
test "curl diagnostics quote shell syntax and redact sensitive headers" {
  let request = @client.request(
    @mttp_core.Request::get("https://example.test/?q='$(cmd)")
    .header("AUTHORIZATION", "secret")
    .header("Cookie", "private")
    .header("x-name", "a'b"),
  )
  assert_eq(
    request.to_curl(),
    "curl --globoff --request 'GET' --header 'authorization: <redacted>' --header 'cookie: <redacted>' --header 'x-name: a'\\''b' --url 'https://example.test/?q='\\''$(cmd)'",
  )
  assert_true(
    request
    .to_curl(sensitive_headers=["X-NAME"])
    .contains("'x-name: <redacted>'"),
  )
  assert_false(
    @client.request(@mttp_core.Request::get("http://user:secret@example.test/"))
    .to_curl()
    .contains("secret"),
  )
  assert_true(
    @client.request(@mttp_core.Request::get("http://["))
    .to_curl()
    .contains("--url 'http://['"),
  )
}

///|
test "curl diagnostics preserve binary bytes without opening a data filename" {
  let request = @client.request(
    @mttp_core.Request::post("/").body_bytes(b"@\x00\xff'\n"),
  )
  assert_eq(
    request.to_curl(),
    "printf '%b' '\\0100\\0000\\0377\\0047\\0012' | curl --globoff --request 'POST' --url '/' --data-binary @- --header 'content-type:'",
  )
  assert_eq(
    request.to_curl(include_body=false),
    "curl --globoff --request 'POST' --url '/' # byte body omitted",
  )
  assert_eq(
    @client.request(
      @mttp_core.Request::post("/").body_bytes(b"", content_type="custom/type"),
    ).to_curl(),
    "printf '%b' '' | curl --globoff --request 'POST' --header 'content-type: custom/type' --url '/' --data-binary @-",
  )
}

///|
test "curl diagnostics never invoke factories or consume streams" {
  let driver = @driver.Driver::new()
  let source = @sim.Feed::bytes(driver, [b"payload"])
  let request = @client.request(
    @mttp_core.Request::post("/").body_stream(source),
  )
  assert_true(request.to_curl().has_suffix("# streaming body omitted"))
  let factory = request.body_fn(() => abort("diagnostics called body factory"))
  assert_true(factory.to_curl().has_suffix("# body factory omitted"))
  @driver.run_sync(() => {
    assert_eq(@mttp_core.read_bounded(source, 7), b"payload")
  })
}

///|
test "redact_headers hides the same credentials as to_curl, and set-cookie" {
  let headers = @mttp_core.Headers::of([
    ("Authorization", "Bearer a"),
    ("proxy-authorization", "Basic b"),
    ("COOKIE", "c=1"),
    ("x-api-key", "k"),
    ("Api-Key", "k2"),
    ("set-cookie", "s=1"),
    ("accept", "text/plain"),
    ("authorization", "second"),
  ])
  assert_eq(
    @client.redact_headers(headers),
    @mttp_core.Headers::of([
      ("Authorization", "<redacted>"),
      ("proxy-authorization", "<redacted>"),
      ("COOKIE", "<redacted>"),
      ("x-api-key", "<redacted>"),
      ("Api-Key", "<redacted>"),
      ("set-cookie", "<redacted>"),
      ("accept", "text/plain"),
      ("authorization", "<redacted>"),
    ]),
  )
  // Every name to_curl hides by default is in the shared list.
  let request = @client.request(
    @mttp_core.Request::get("https://example.test/")
    .header("x-api-key", "k")
    .header("api-key", "k2"),
  )
  assert_false(request.to_curl().contains("k2"))
  assert_true(@client.default_sensitive_headers.contains("authorization"))
  // A caller's own list replaces the default, ignoring case.
  assert_eq(
    @client.redact_headers(headers, names=["ACCEPT"]).get("accept"),
    Some("<redacted>"),
  )
  assert_eq(
    @client.redact_headers(headers, names=["ACCEPT"]).get("authorization"),
    Some("Bearer a"),
  )
}

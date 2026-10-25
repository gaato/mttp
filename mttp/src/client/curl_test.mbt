///|
test "curl diagnostics quote shell syntax and redact sensitive headers" {
  let request = @client.quick_request(
    @model.Request::get("https://example.test/?q='$(cmd)")
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
    @client.quick_request(
      @model.Request::get("http://user:secret@example.test/"),
    )
    .to_curl()
    .contains("secret"),
  )
  assert_true(
    @client.quick_request(@model.Request::get("http://["))
    .to_curl()
    .contains("--url 'http://['"),
  )
}

///|
test "curl diagnostics preserve binary bytes without opening a data filename" {
  let request = @client.quick_request(
    @model.Request::post("/").body_bytes(b"@\x00\xff'\n"),
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
    @client.quick_request(
      @model.Request::post("/").body_bytes(b"", content_type="custom/type"),
    ).to_curl(),
    "printf '%b' '' | curl --globoff --request 'POST' --header 'content-type: custom/type' --url '/' --data-binary @-",
  )
}

///|
test "curl diagnostics never invoke factories or consume streams" {
  let driver = @driver.Driver::new()
  let source = @feed.Feed::bytes(driver, [b"payload"])
  let request = @client.quick_request(
    @model.Request::post("/").body_stream(source),
  )
  assert_true(request.to_curl().has_suffix("# streaming body omitted"))
  let factory = request.body_fn(() => abort("diagnostics called body factory"))
  assert_true(factory.to_curl().has_suffix("# body factory omitted"))
  @driver.run_sync(() => assert_eq(@model.read_bounded(source, 7), b"payload"))
}

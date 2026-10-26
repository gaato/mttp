///|
test "PATCH OPTIONS and Basic builders preserve request values" {
  assert_eq(@model.Request::patch("/items").meth, Patch)
  assert_eq(@model.Request::options("/items").meth, Options)
  let original = @model.Request::get("/").bearer("old")
  let authenticated = original.basic("Aladdin", "open sesame")
  assert_eq(authenticated.headers.get_all("authorization"), [
    "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==",
  ])
  assert_eq(original.headers.get("authorization"), Some("Bearer old"))
}

///|
test "prefix URL joining preserves mixed-case absolute HTTP schemes" {
  for
    absolute in [
      "HTTP://example.test/a", "Https://example.test/a", "hTtPs://example.test/a",
    ] {
    assert_eq(@model.join_url("https://api.test/v1", absolute), absolute)
  }
  assert_eq(
    @model.join_url("https://api.test/v1", "/a"),
    "https://api.test/v1/a",
  )
}

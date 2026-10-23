///|
test "uri: §3.3 usage example (returns the encoded target string)" {
  let id = "a/b c"
  let q : String? = None
  let u = @model.uri(b => b <+ "https://api.example.com/users/\{id}?q=\{q}&n=\{3}")
  assert_eq(u, "https://api.example.com/users/a%2Fb%20c?n=3")
  assert_eq(@model.Url::parse(u).path_segments(), ["users", "a/b c"])
}

///|
test "join_url keeps the base path (CM-01 cases)" {
  assert_eq(@model.join_url("https://api.openai.com/v1", "/chat/completions"), "https://api.openai.com/v1/chat/completions")
  assert_eq(@model.join_url("https://ghe.example.com/api/v3/", "/repos/o/r"), "https://ghe.example.com/api/v3/repos/o/r")
  assert_eq(@model.join_url("https://discord.com/api/v10", "/gateway"), "https://discord.com/api/v10/gateway")
  assert_eq(@model.join_url("https://a", "https://b/x"), "https://b/x")
  assert_eq(@model.join_url("", "/x"), "/x")
  // RFC 3986 resolution is a different operation and drops the base path:
  let r = @model.Url::parse("https://api.openai.com/v1").resolve(@model.Url::parse("/chat"))
  assert_eq(r.to_string(), "https://api.openai.com/chat")
}

///|
test "Method implements Show" {
  let m : @model.Method = Patch
  assert_eq("m=\{m}", "m=PATCH")
}

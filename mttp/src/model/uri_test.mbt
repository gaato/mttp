///|
test "URI interpolation escapes components and optional query values" {
  let id = "a/b c"
  let none : String? = None
  let text = @model.uri(b => {
    b <+ "https://api.example.com/users/\{id}?q=\{none}&n=\{3}"
  })
  assert_eq(text, "https://api.example.com/users/a%2Fb%20c?n=3")
  assert_eq(@model.Url::parse(text).path_segments(), ["users", "a/b c"])
  let value = "a&b=#?字"
  assert_eq(
    @model.uri(b => b <+ "/\{value}?q=\{value}#\{value}"),
    "/a%26b%3D%23%3F%E5%AD%97?q=a%26b%3D%23%3F%E5%AD%97#a%26b%3D%23%3F%E5%AD%97",
  )
  assert_eq(@model.uri(b => b <+ "?a=\{Some("x")}&b=\{none}#end"), "?a=x#end")
  assert_eq(@model.uri(b => b <+ "?a=\{none}&b=\{none}"), "")
  assert_eq(
    @model.uri(b => b <+ "/\{none}?a=prefix\{none}suffix&b=yes"),
    "/?b=yes",
  )
}

///|
test "URI literal structure and trusted bases remain distinct from data" {
  assert_eq(@model.uri(b => b <+ "/path#fragment"), "/path#fragment")
  let base = "https://example.test/root"
  assert_eq(
    @model.uri(b => b <+ "\{base}"),
    "https%3A%2F%2Fexample.test%2Froot",
  )
  assert_eq(
    @model.uri(b => b <+ "\{@model.Trusted(base)}?n=\{2L}&yes=\{true}&x=\{1.5}"),
    "https://example.test/root?n=2&yes=true&x=1.5",
  )
  assert_eq(@model.uri(b => b <+ "/?#?&=x"), "/#?&=x")
  assert_eq(@model.uri(b => b <+ "?&&a?b=c=d&&"), "?a?b=c=d")
}

///|
test "URI query arrays retain duplicate names and cannot inject structure elsewhere" {
  let pairs = [("a&", "b="), ("a&", "x y")]
  assert_eq(
    @model.uri(b => b <+ "?\{pairs}&end=yes"),
    "?a%26=b%3D&a%26=x%20y&end=yes",
  )
  let empty : Array[(String, String)] = []
  assert_eq(@model.uri(b => b <+ "?\{empty}&x=y"), "?x=y")
  assert_eq(
    @model.uri(b => b <+ "/\{pairs}"),
    "/a%2526%3Db%253D%26a%2526%3Dx%2By",
  )
  assert_eq(
    @model.uri(b => b <+ "?prefix\{pairs}"),
    "?prefixa%2526%3Db%253D%26a%2526%3Dx%2By",
  )
}

///|
test "URI builder snapshots do not consume staged parameters" {
  let builder = @model.UriBuilder::new()
  builder.write_string("/p?a=")
  builder.write_encoded("x y")
  assert_eq(builder.to_string(), "/p?a=x%20y")
  assert_eq(builder.to_string(), "/p?a=x%20y")
  builder.write_string("&b=2")
  assert_eq(builder.to_string(), "/p?a=x%20y&b=2")
  let many = "x".repeat(100000)
  assert_eq(@model.uri(b => b.write_string(many)), many)
}

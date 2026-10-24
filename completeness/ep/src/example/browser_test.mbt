///|
test "endpoint client halves run without an async runtime" {
  let seen = []
  let ok = @example.browser_side(req => {
    seen.push(req.uri.to_string())
    seen.push(req.headers.get("authorization").unwrap_or("-"))
    ({ status: @model.Status(200), headers: @model.Headers::new() }, b"{\"id\":1,\"name\":\"gaato\"}")
  })
  inspect(ok, content="gaato")
  inspect(seen, content=(
    #|[/users/1, Bearer secret]
  ))
  let missing = @example.browser_side(_ => (
    { status: @model.Status(404), headers: @model.Headers::new() },
    b"1",
  ))
  inspect(missing, content="no user 1")
}

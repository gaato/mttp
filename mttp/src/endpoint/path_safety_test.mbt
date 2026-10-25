///|
test "typed requests reject dot-only captures before transport" {
  let ep = @endpoint.endpoint
    .get("/items/{id}")
    .input(@endpoint.path("id", @schema.string))
  let rest = @endpoint.endpoint
    .get("/items/{tail...}")
    .input(@endpoint.paths("tail"))
  for value in [".", ".."] {
    try ep.request((), value) catch {
      @client.InvalidRequest(..) => ()
    } noraise {
      _ => fail("accepted dot-only capture")
    }
    try rest.request((), ["a", value, "b"]) catch {
      @client.InvalidRequest(..) => ()
    } noraise {
      _ => fail("accepted dot-only rest segment")
    }
  }
  for value in ["a.b", "...", "%2e", "a/b", ""] {
    ignore(ep.request((), value))
    ignore(rest.request((), [value]))
  }
  let custom = @endpoint.endpoint
    .get("/items/{tail...}")
    .input(
      @endpoint.Input::new(
        [@endpoint.Atom::new(Path, "tail", @schema.string.schema(), rest=true)],
        _ => @endpoint.Staged::ready(""),
        (value, sink) => sink.set_capture("tail", value),
      ),
    )
  for value in ["/%2e", "/.%2E", "/%"] {
    try custom.request((), value) catch {
      @client.InvalidRequest(..) => ()
    } noraise {
      _ => fail("accepted unsafe custom rest encoding")
    }
  }
}

///|
test "OpenAPI refuses equivalent templates with renamed captures across methods" {
  let get = @endpoint.endpoint
    .get("/pets/{id}")
    .input(@endpoint.path("id", @schema.string))
  let delete = @endpoint.endpoint
    .delete("/pets/{name}")
    .input(@endpoint.path("name", @schema.string))
  let rest = @endpoint.endpoint
    .delete("/pets/{tail...}")
    .input(@endpoint.paths("tail"))
  for
    docs in [
      [get.doc(), delete.doc()],
      [delete.doc(), get.doc()],
      [get.doc(), rest.doc()],
    ] {
    let expected = @endpoint.check_definitions(docs)
    try
      ignore(@openapi.to_openapi(docs, @apispec.Info::new("Test", "1")))
    catch {
      @endpoint.DefinitionError(problems) => {
        assert_eq(problems, expected)
        assert_true(
          problems
          .iter()
          .any(p => {
            p.fatal &&
            p.message.has_prefix(
              "path capture names differ from equivalent template ",
            )
          }),
        )
      }
    } noraise {
      _ => fail("equivalent templates with renamed captures were projected")
    }
  }
}

///|
test "OpenAPI merges methods under one consistently named path item" {
  let get = @endpoint.endpoint
    .get("/pets/{id}")
    .input(@endpoint.path("id", @schema.string))
  let delete = @endpoint.endpoint
    .delete("/pets/{id}")
    .input(@endpoint.path("id", @schema.string))
  let rest = @endpoint.endpoint
    .delete("/pets/{id...}")
    .input(@endpoint.paths("id"))
  for
    docs in [
      [get.doc(), delete.doc()],
      [delete.doc(), get.doc()],
      [get.doc(), rest.doc()],
    ] {
    let spec = @openapi.to_openapi(docs, @apispec.Info::new("Test", "1"))
    assert_eq(spec.paths.length(), 1)
    let item = spec.paths["/pets/{id}"]
    assert_eq(item.operations.length(), 2)
    assert_eq(item.operations["get"].parameters[0].name, "id")
    assert_eq(item.operations["delete"].parameters[0].name, "id")
    assert_eq(@openapi.check_references(spec), [])
  }
}

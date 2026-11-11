///|
fn capture_docs(
  first : String,
  second : String,
  rest~ : Bool = false,
) -> Array[@endpoint.EndpointDoc] {
  let suffix = if rest { "...}" } else { "}" }
  let a = @endpoint.endpoint.get("/pets/{" + first + suffix)
  let b = @endpoint.endpoint.delete("/pets/{" + second + suffix)
  if rest {
    [
      a.input(@endpoint.paths(first)).doc(),
      b.input(@endpoint.paths(second)).doc(),
    ]
  } else {
    [
      a.input(@endpoint.path(first, @schema.string)).doc(),
      b.input(@endpoint.path(second, @schema.string)).doc(),
    ]
  }
}

///|
test "equivalent templates with different capture names are fatal across methods" {
  for rest in [false, true] {
    let docs = capture_docs("id", "name", rest~)
    for ordered in [docs, [docs[1], docs[0]]] {
      let problems = @endpoint.check_definitions(ordered)
      assert_true(
        problems
        .iter()
        .any(p => {
          p.fatal &&
          p.template == ordered[1].template &&
          p.message ==
          "path capture names differ from equivalent template " +
          ordered[0].template
        }),
      )
    }
  }
  let first = @endpoint.endpoint
    .get("/orgs/{org}/pets/{id}")
    .input(
      @endpoint.pair(
        @endpoint.path("org", @schema.string),
        @endpoint.path("id", @schema.string),
      ),
    )
  let second = @endpoint.endpoint
    .delete("/orgs/{id}/pets/{org}")
    .input(
      @endpoint.pair(
        @endpoint.path("id", @schema.string),
        @endpoint.path("org", @schema.string),
      ),
    )
  assert_true(
    @endpoint.check_definitions([first.doc(), second.doc()])
    .iter()
    .any(p => p.fatal),
  )
  let rest = @endpoint.endpoint
    .delete("/pets/{tail...}")
    .input(@endpoint.paths("tail"))
  let single = @endpoint.endpoint
    .get("/pets/{id}")
    .input(@endpoint.path("id", @schema.string))
  assert_true(
    @endpoint.check_definitions([single.doc(), rest.doc()])
    .iter()
    .any(p => p.fatal),
  )
}

///|
test "consistent capture names across methods and distinct hierarchies stay valid" {
  for rest in [false, true] {
    assert_eq(@endpoint.check_definitions(capture_docs("id", "id", rest~)), [])
  }
  let id = @endpoint.endpoint
    .get("/pets/{id}")
    .input(@endpoint.path("id", @schema.string))
  let name = @endpoint.endpoint
    .delete("/owners/{name}")
    .input(@endpoint.path("name", @schema.string))
  let longer = @endpoint.endpoint
    .delete("/pets/{name}/photos")
    .input(@endpoint.path("name", @schema.string))
  let rest = @endpoint.endpoint
    .delete("/pets/{id...}")
    .input(@endpoint.paths("id"))
  assert_eq(
    @endpoint.check_definitions([id.doc(), name.doc(), longer.doc(), rest.doc()]),
    [],
  )
}

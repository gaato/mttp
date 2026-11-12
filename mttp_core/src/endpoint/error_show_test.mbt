///|
test "definition and input errors interpolate their entries" {
  let definition = @endpoint.DefinitionError([
    @endpoint.DefinitionProblem::new("/a", "duplicate input"),
    @endpoint.DefinitionProblem::new("/b", "bad pattern"),
  ])
  assert_eq(
    "\{definition}",
    "endpoint definition problems: /a: duplicate input; /b: bad pattern",
  )
  let input = @endpoint.InputErrors([
    @endpoint.InputFailure::new(
      @endpoint.Atom::new(Query, "limit", @schema.int.schema()),
      @schema.DecodeFailure(kind=Malformed, message="not a number"),
    ),
  ])
  assert_eq("\{input}", "invalid input: limit: not a number")
}

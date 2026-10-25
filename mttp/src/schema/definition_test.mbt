///|
test "schema conflicts survive composition without overwriting earlier definitions" {
  let defs : Map[String, Json] = Map([])
  let problems = []
  let first = @schema.Schema::of({ "type": "string" }).named("Same")
  let second = @schema.Schema::of({ "type": "integer" }).named("Same")
  ignore(first.reference(defs, problems~))
  ignore(second.reference(defs, problems~))
  assert_eq(defs["Same"], { "type": "string" })
  assert_eq(problems, ["conflicting schema definition Same"])
  let a = @schema.JsonCodec::new(j => j, j => j, first)
  let b = @schema.JsonCodec::new(j => j, j => j, second)
  let obj : @schema.JsonCodec[(Json, Json)] = @schema.object2(
    "Object",
    @schema.field("a", a, value => value.0),
    @schema.field("b", b, value => value.1),
    (a, b) => (a, b),
  )
  let nested = @schema.map_of(@schema.option(@schema.array(obj)))
  assert_eq(nested.schema().problems, ["conflicting schema definition Same"])
  let duplicate : @schema.JsonCodec[(Int32, Int32)] = @schema.object2(
    "Duplicate",
    @schema.field("same", @schema.jint, value => value.0),
    @schema.field("same", @schema.jint, value => value.1),
    (a, b) => (a, b),
  )
  assert_eq(duplicate.schema().problems, ["duplicate object field same"])
}

///|
test "impossible validators emit valid false constraints" {
  let max = @schema.string.validate(@schema.max_length(-1))
  let rejected = try {
    ignore(max.decode(""))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(max.schema().json, { "type": "string", "not": {} })
  let min = @schema.string.validate(@schema.min_length(-1))
  assert_eq(min.decode(""), "")
  assert_eq(min.schema().json, { "type": "string", "minLength": 0 })
  let empty : @schema.TextCodec[String] = @schema.string.validate(
    @schema.one_of_values([]),
  )
  assert_eq(empty.schema().json, { "type": "string", "not": {} })
}

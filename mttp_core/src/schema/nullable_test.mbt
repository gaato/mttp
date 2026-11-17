///|
test "nullable requires the key and encodes None as explicit null" {
  let codec = @schema.object1(
    "RequiredNullable",
    @schema.field("value", @schema.nullable(@schema.jstring), x => x),
    x => x,
  )
  assert_eq(codec.from_json({ "value": null }), None)
  assert_eq(codec.from_json({ "value": "hello" }), Some("hello"))
  assert_eq(codec.to_json(None), { "value": null })
  assert_eq(codec.to_json(Some("hello")), { "value": "hello" })
  let issues = try {
    ignore(codec.from_json({}))
    []
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) => issues
    other => fail("unexpected error: \{other}")
  }
  assert_eq(issues, [@schema.Issue::new("missing", "required", path="/value")])
  assert_eq(codec.schema().json, {
    "type": "object",
    "properties": {
      "value": { "anyOf": [{ "type": "string" }, { "type": "null" }] },
    },
    "required": ["value"],
  })
}

///|
test "nullable preserves child definitions validation and collection nulls" {
  let child = @schema.object1(
    "Child",
    @schema.field("n", @schema.jint, x => x),
    x => x,
  )
  let codec = @schema.nullable(child)
  assert_eq(codec.schema().defs["Child"], child.schema().json)
  assert_eq(codec.schema().json, {
    "anyOf": [{ "$ref": "#/components/schemas/Child" }, { "type": "null" }],
  })
  let validated = @schema.nullable(
    @schema.jstring.validate(@schema.max_length(2)),
  )
  assert_eq(validated.from_json(null), None)
  let issues = try {
    ignore(validated.from_json("long"))
    []
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) => issues
    other => fail("unexpected error: \{other}")
  }
  assert_eq(issues.length(), 1)
  assert_eq(@schema.array(codec).to_json([None, Some(1)]), [null, { "n": 1 }])
}

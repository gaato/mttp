///|
test "codec descriptions preserve validation optionality and source schema" {
  let base = @schema.omittable(@schema.jstring.validate(@schema.max_length(2)))
  let codec = base.with_description("A short name")
  assert_eq(codec.schema().json, {
    "type": "string",
    "maxLength": 2,
    "description": "A short name",
  })
  assert_eq(base.schema().json, { "type": "string", "maxLength": 2 })
  assert_eq(codec.from_json("ok"), Some("ok"))
  assert_eq(codec.to_json(Some("ok")), "ok")
  assert_true((codec.from_json("long") catch { _ => None }) is None)
  let object = @schema.object1(
    "Optional",
    @schema.field("name", codec, x => x),
    x => x,
  )
  assert_eq(object.from_json({}), None)
  assert_eq(object.to_json(None), {})
  assert_true(
    try {
      ignore(object.from_json({ "name": null }))
      false
    } catch {
      _ => true
    },
  )
}

///|
test "field descriptions are reference siblings and do not alter shared definitions" {
  let child = @schema.object1(
    "Child",
    @schema.field("id", @schema.jint, x => x),
    x => x,
  ).with_description("Shared child")
  let parent = @schema.object2(
    "Parent",
    @schema.field(
      "left",
      child,
      (p : (Int32, Int32)) => p.0,
      description="Left child",
    ),
    @schema.field(
      "right",
      child,
      (p : (Int32, Int32)) => p.1,
      description="Right child",
    ),
    (left, right) => (left, right),
  )
  assert_eq(parent.schema().json, {
    "type": "object",
    "properties": {
      "left": {
        "$ref": "#/components/schemas/Child",
        "description": "Left child",
      },
      "right": {
        "$ref": "#/components/schemas/Child",
        "description": "Right child",
      },
    },
    "required": ["left", "right"],
  })
  assert_eq(parent.schema().defs["Child"], child.schema().json)
  assert_eq(parent.schema().problems, [])
  assert_eq(
    parent.from_json({ "left": { "id": 1 }, "right": { "id": 2 } }),
    (1, 2),
  )
}

///|
test "field descriptions override inline text without mutating codec metadata" {
  let base = @schema.jint.with_description("Value")
  let codec = @schema.object1(
    "Count",
    @schema.field("n", base, x => x, description=""),
    x => x,
  )
  assert_eq(codec.schema().json, {
    "type": "object",
    "properties": {
      "n": { "type": "integer", "format": "int32", "description": "" },
    },
    "required": ["n"],
  })
  assert_eq(base.schema().json, {
    "type": "integer",
    "format": "int32",
    "description": "Value",
  })
}

///|
test "descriptions handle boolean JSON schemas" {
  let base = @schema.JsonCodec::new(j => j, j => j, @schema.Schema::of(true))
  assert_eq(base.with_description("Anything").schema().json, {
    "allOf": [true, { "description": "Anything" }],
  })
  let codec = @schema.object1(
    "Anything",
    @schema.field("v", base, x => x, description="Value"),
    x => x,
  )
  assert_eq(codec.schema().json, {
    "type": "object",
    "properties": { "v": { "allOf": [true], "description": "Value" } },
    "required": ["v"],
  })
  assert_eq(codec.from_json({ "v": null }), null)
}

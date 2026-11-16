///|
test "JSON annotations use the mapped encoder and preserve decoding and definitions" {
  let codec = @schema.jint.map(n => n.to_string(), s => {
    @string.parse_int(s) catch {
      _ => 0
    }
  })
  let annotated = codec.with_examples([7]).with_default("8")
  json_inspect(annotated.schema().json, content={
    "type": "integer",
    "format": "int32",
    "examples": [7],
    "default": 8,
  })
  assert_eq(annotated.from_json(9), "9")
  assert_eq(annotated.to_json("10"), 10)
  assert_eq(codec.schema().json, @schema.jint.schema().json)
  let named = @schema.JsonCodec::new(
      j => @schema.jint.from_json(j),
      n => Json(n),
      @schema.jint.schema().named("Count"),
    )
    .with_default(2)
    .with_examples([1, 2])
  let definitions = Map([])
  assert_eq(named.schema().reference(definitions), {
    "$ref": "#/components/schemas/Count",
  })
  assert_eq(definitions["Count"], named.schema().json)
}

///|
test "text defaults retain custom wire mappings and examples copy their array" {
  let examples : Array[Json] = ["wire:4"]
  let codec = @schema.string
    .map(s => s.length(), n => "wire:" + n.to_string())
    .with_examples(examples)
    .with_default(4)
  examples.push("later")
  json_inspect(codec.schema().json, content={
    "type": "string",
    "examples": ["wire:4"],
    "default": "wire:4",
  })
  assert_eq(codec.decode("abc"), 3)
  assert_eq(codec.encode(5), "wire:5")
  assert_eq(@schema.int.with_default(4).schema().json, {
    "type": "integer",
    "format": "int32",
    "default": "4",
  })
}

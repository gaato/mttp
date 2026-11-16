///|
test "object16 round trips all fields and collects every field failure" {
  let codec : @schema.JsonCodec[Array[Int32]] = @schema.object16(
    "Wide",
    @schema.field("a0", @schema.jint, v => v[0]),
    @schema.field("a1", @schema.jint, v => v[1]),
    @schema.field("a2", @schema.jint, v => v[2]),
    @schema.field("a3", @schema.jint, v => v[3]),
    @schema.field("a4", @schema.jint, v => v[4]),
    @schema.field("a5", @schema.jint, v => v[5]),
    @schema.field("a6", @schema.jint, v => v[6]),
    @schema.field("a7", @schema.jint, v => v[7]),
    @schema.field("a8", @schema.jint, v => v[8]),
    @schema.field("a9", @schema.jint, v => v[9]),
    @schema.field("a10", @schema.jint, v => v[10]),
    @schema.field("a11", @schema.jint, v => v[11]),
    @schema.field("a12", @schema.jint, v => v[12]),
    @schema.field("a13", @schema.jint, v => v[13]),
    @schema.field("a14", @schema.jint, v => v[14]),
    @schema.field("a15", @schema.jint, v => v[15]),
    (a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15) => {
      [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15]
    },
  )
  let value = Array::makei(16, i => i)
  let json = codec.to_json(value)
  assert_eq(codec.from_json(json), value)
  for i in 0..<16 {
    assert_eq(property(json, "a\{i}"), Some(Json(i)))
  }
  let schema = codec.schema()
  assert_eq(schema.name, Some("Wide"))
  assert_eq(
    property(schema.json, "required"),
    Some(Json(Array::makei(16, i => "a\{i}"))),
  )
  try {
    ignore(codec.from_json({}))
    fail("missing fields accepted")
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) =>
      assert_eq(issues.map(i => i.path), Array::makei(16, i => "/a\{i}"))
    error => raise error
  }
  try {
    ignore(
      codec.from_json(
        Json::object(
          Map::from_array(Array::makei(16, i => ("a\{i}", Json(false)))),
        ),
      ),
    )
    fail("invalid fields accepted")
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) =>
      assert_eq(issues.length(), 16)
    error => raise error
  }
}

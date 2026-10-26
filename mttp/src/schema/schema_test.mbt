///|
fn property(json : Json, key : String) -> Json? {
  if json is Object(obj) {
    obj.get(key)
  } else {
    None
  }
}

///|
fn[T] identity(value : T) -> T {
  value
}

///|
fn[T] rejects(f : () -> T raise @schema.DecodeFailure) -> Unit raise {
  try {
    let _ = f()
    fail("invalid input accepted")
  } catch {
    @schema.DecodeFailure(..) => ()
    error => raise error
  }
}

///|
test "text codecs check bounds, format values and keep validation schemas" {
  assert_eq(@schema.string.encode("hello"), "hello")
  let bounded = @schema.int
    .validate(@schema.minimum(2))
    .validate(@schema.maximum(5))
  assert_eq(bounded.decode("3"), 3)
  assert_eq(bounded.encode(4), "4")
  rejects(() => bounded.decode("1"))
  rejects(() => bounded.decode("6"))
  rejects(() => bounded.decode("x"))
  assert_eq(bounded.schema().json, {
    "type": "integer",
    "format": "int32",
    "minimum": 2,
    "maximum": 5,
  })
  let twice = @schema.int
    .validate(@schema.minimum(1))
    .validate(@schema.minimum(2))
  assert_eq(
    property(twice.schema().json, "allOf"),
    Some(Json::array([{ "minimum": 2 }])),
  )
  let text = @schema.string
    .validate(@schema.min_length(1))
    .validate(@schema.max_length(1))
  assert_eq(text.decode("😀"), "😀")
  rejects(() => text.decode(""))
  rejects(() => text.decode("ab"))
  assert_eq(@schema.int64.decode("9223372036854775807"), 9223372036854775807L)
  rejects(() => @schema.int64.decode("9223372036854775808"))
  assert_eq(@schema.int64.encode(-4), "-4")
  assert_eq(@schema.double.decode("1.5"), 1.5)
  assert_eq(@schema.double.encode(1.5), "1.5")
  for text in ["bad", "NaN", "Infinity"] {
    rejects(() => @schema.double.decode(text))
  }
  assert_true(@schema.bool.decode("true"))
  assert_false(@schema.bool.decode("false"))
  assert_eq(@schema.bool.encode(false), "false")
  rejects(() => @schema.bool.decode("TRUE"))
  let values = ["a", "b"]
  let enum_ = @schema.enum_of(values)
  values.push("c")
  assert_eq(enum_.decode("a"), "a")
  rejects(() => enum_.decode("c"))
  let mapped = @schema.int.map(i => i.to_string(), s => {
    @schema.int.decode(s) catch {
      _ => 0
    }
  })
  assert_eq(mapped.decode("3"), "3")
  assert_eq(mapped.encode("4"), "4")
}

///|
test "JSON primitives enforce types and preserve exact 64-bit numbers" {
  assert_true(@schema.jbool.from_json(true))
  assert_false(@schema.jbool.from_json(false))
  assert_eq(@schema.jbool.to_json(true), Json(true))
  rejects(() => @schema.jbool.from_json(1))
  assert_eq(@schema.jdouble.from_json(1.5), 1.5)
  assert_eq(@schema.jdouble.to_json(2.0), Json(2.0))
  rejects(() => @schema.jdouble.from_json("2"))
  assert_eq(@schema.jint.from_json(-2147483648), -2147483648)
  for value in [Json(2147483648.0), Json(1.5), Json("1")] {
    rejects(() => @schema.jint.from_json(value))
  }
  assert_eq(@schema.jint.to_json(3), Json(3))
  assert_eq(@schema.jstring.from_json("a"), "a")
  assert_eq(@schema.jstring.to_json("a"), Json("a"))
  rejects(() => @schema.jstring.from_json(false))
  let codec = @schema.jint64.body()
  for
    (text, value) in [
      ("9223372036854775807", 9223372036854775807L),
      ("-9223372036854775808", -9223372036854775808L),
      ("12.00e+2", 1200L),
      ("120e-1", 12L),
      ("-0.00", 0L),
      ("1e+3", 1000L),
      ("1E3", 1000L),
    ] {
    assert_eq(codec.decode(@utf8.encode(text)), value)
    assert_eq(codec.decode(codec.encode(value)), value)
  }
  for
    text in [
      "9223372036854775808", "-9223372036854775809", "1.2", "1e-2", "1e20", "1e99999999",
      "true", "\"1\"",
    ] {
    rejects(() => codec.decode(@utf8.encode(text)))
  }
  assert_eq(@schema.jint64.from_json(123), 123L)
  rejects(() => @schema.jint64.from_json(Json::number(9007199254740992.0)))
  let enum_ = @schema.string_enum("Color", ["red"])
  assert_eq(enum_.from_json("red"), "red")
  assert_eq(enum_.schema().name, Some("Color"))
  rejects(() => enum_.from_json("blue"))
  let mapped = @schema.jint.map(i => i.to_string(), _ => 2)
  assert_eq(mapped.from_json(3), "3")
  assert_eq(mapped.to_json("x"), Json(2))
  assert_eq(@schema.jvalue.from_json({ "a": 1 }), { "a": 1 })
  assert_eq(@schema.jvalue.to_json(false), Json(false))
}

///|
test "object and array codecs collect every issue with escaped pointer paths" {
  let pair : @schema.JsonCodec[(Int32, String)] = @schema.object2(
    "Pair",
    @schema.field("a/b~", @schema.jint, p => p.0),
    @schema.field("b", @schema.jstring, p => p.1),
    (a, b) => (a, b),
  )
  assert_eq(pair.from_json({ "a/b~": 2, "b": "x" }), (2, "x"))
  assert_eq(pair.to_json((2, "x")), { "a/b~": 2, "b": "x" })
  try {
    let _ = @schema.array(pair).from_json([
      { "a/b~": "x" },
      { "a/b~": 1, "b": false },
    ])
    fail("invalid fields accepted")
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) =>
      assert_eq(issues.map(i => i.path), ["/0/a~1b~0", "/0/b", "/1/b"])
    error => raise error
  }
  rejects(() => pair.from_json(false))
  rejects(() => @schema.array(pair).from_json(false))
  assert_eq(@schema.array(pair).from_json([{ "a/b~": 1, "b": "x" }]), [(1, "x")])
  assert_eq(@schema.array(pair).to_json([(1, "x")]), [{ "a/b~": 1, "b": "x" }])
  let one = @schema.object1(
    "One",
    @schema.field("x", @schema.jint, identity),
    identity,
  )
  assert_eq(one.from_json({ "x": 3 }), 3)
  assert_eq(one.to_json(3), { "x": 3 })
  rejects(() => one.from_json({}))
  rejects(() => one.from_json(false))
}

///|
test "schema references retain children and constraints without mutating input" {
  let child = @schema.object1(
    "A/B~",
    @schema.field("x", @schema.jint, v => v),
    v => v,
  )
  let parent = @schema.array(child)
  let defs : Map[String, Json] = Map([])
  assert_eq(parent.schema().reference(defs), {
    "type": "array",
    "items": { "$ref": "#/components/schemas/A~1B~0" },
  })
  assert_eq(defs.get("A/B~"), Some(child.schema().json))
  let schema = @schema.Schema::of(true).patch({ "type": "string" })
  assert_eq(schema.json, { "allOf": [true, { "type": "string" }] })
  let original = @schema.Schema::of({
    "minimum": 1,
    "allOf": [{ "maximum": 10 }],
  })
  let patched = original.patch({ "minimum": 2 })
  assert_eq(property(original.json, "minimum"), Some(Json(1)))
  assert_eq(
    property(patched.json, "allOf"),
    Some(Json::array([{ "maximum": 10 }, { "minimum": 2 }])),
  )
}

///|
test "body codecs reject invalid UTF8 JSON duplicates and excessive nesting" {
  assert_eq(@schema.text_body.decode(b"hi"), "hi")
  assert_eq(@schema.text_body.encode("hi"), b"hi")
  assert_eq(@schema.text_body.media_type(), "text/plain")
  assert_eq(@schema.text_body.schema().json, { "type": "string" })
  rejects(() => @schema.text_body.decode(b"\xff"))
  assert_eq(@schema.raw_bytes.decode(b"\xff"), b"\xff")
  assert_eq(@schema.raw_bytes.encode(b"\x00"), b"\x00")
  let body = @schema.jvalue.body()
  let _ = body.decode(@utf8.encode("[".repeat(128) + "0" + "]".repeat(128)))
  assert_eq(body.media_type(), "application/json")
  rejects(() => body.decode(b"\xff"))
  rejects(() => body.decode(b"{"))
  rejects(() => body.decode(b"{\"a\":1,\"a\":2}"))
  rejects(() => {
    body.decode(@utf8.encode("[".repeat(129) + "0" + "]".repeat(129)))
  })
}

///|
struct Derived {
  n : Int32
} derive(FromJson, ToJson)

///|
impl @schema.JsonSchema for Derived with fn json_schema(_) {
  @schema.Schema::of({
    "type": "object",
    "properties": { "n": { "type": "integer" } },
    "required": ["n"],
  })
}

///|
test "derived codecs and custom body codecs retain their declared schemas" {
  let codec : @schema.JsonCodec[Derived] = @schema.json()
  assert_eq(codec.from_json({ "n": 2 }).n, 2)
  assert_eq(codec.to_json(Derived::{ n: 2, }), { "n": 2 })
  rejects(() => codec.from_json({ "n": "bad" }))
  let custom = @schema.BodyCodec::new(
    "custom/type",
    bytes => bytes.length(),
    _ => b"x",
    @schema.Schema::of({ "type": "integer" }),
  )
  assert_eq(custom.decode(b"abc"), 3)
  assert_eq(custom.encode(2), b"x")
  assert_eq(custom.media_type(), "custom/type")
  assert_eq(custom.schema().json, { "type": "integer" })
  assert_eq(@schema.Issue::new("code", "message", path="/a").to_json(), {
    "path": "/a",
    "code": "code",
    "message": "message",
  })
}

///|
test "exact integer decoding validates supplied decimal lexemes without overflow" {
  for
    repr in [
      "", "-", ".0", "1.", "01", "1a", "1e", "1e+", "1eX", "1e99999999999", "1.01",
    ] {
    rejects(() => @schema.jint64.from_json(Json::number(0, repr~)))
  }
  assert_eq(
    @schema.jint64.from_json(Json::number(0, repr="0e999999999999999999999")),
    0L,
  )
}

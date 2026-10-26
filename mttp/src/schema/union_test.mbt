///|
enum Example {
  Number(Int32)
  Text(String)
} derive(Eq, Debug)

///|
fn number_case(object~ : Bool = true) -> @schema.Case[Example] {
  let codec = if object {
    @schema.object1(
      "Number",
      @schema.field("value", @schema.jint, identity),
      identity,
    )
  } else {
    @schema.jint
  }
  @schema.case_("n", codec, x => if x is Number(n) { Some(n) } else { None }, n => {
    Number(n)
  })
}

///|
fn text_case(object~ : Bool = true) -> @schema.Case[Example] {
  let codec = if object {
    @schema.object1(
      "Text",
      @schema.field("value", @schema.jstring, identity),
      identity,
    )
  } else {
    @schema.jstring
  }
  @schema.case_("s", codec, x => if x is Text(s) { Some(s) } else { None }, s => {
    Text(s)
  })
}

///|
test "tagged unions round-trip payloads and describe discriminator constraints" {
  let codec = @schema.tagged("Example", "kind", [number_case(), text_case()])
  for
    (value, json) in [
      (Number(3), Json::object(Map([("kind", Json("n")), ("value", Json(3))]))),
      (
        Text("x"),
        Json::object(Map([("kind", Json("s")), ("value", Json("x"))])),
      ),
    ] {
    assert_eq(codec.from_json(json), value)
    assert_eq(codec.to_json(value), json)
  }
  for
    json in [
      Json(false),
      Json::empty_object(),
      { "kind": 1 },
      { "kind": "unknown" },
      { "kind": "n", "value": "x" },
    ] {
    rejects(() => codec.from_json(json))
  }
  assert_eq(
    property(codec.schema().json, "discriminator"),
    Some({
      "propertyName": "kind",
      "mapping": {
        "n": "#/components/schemas/Example/oneOf/0",
        "s": "#/components/schemas/Example/oneOf/1",
      },
    }),
  )
  assert_true(codec.schema().defs.contains("Number"))
  assert_true(codec.schema().defs.contains("Text"))
  let open = @schema.open_string(["known"])
  assert_eq(open.from_json("new"), "new")
  assert_eq(open.to_json("new"), Json("new"))
}

///|
test "untagged unions choose the first successful case and collect failures" {
  let codec = @schema.any_of("Either", [
    number_case(object=false),
    text_case(object=false),
  ])
  assert_eq(codec.from_json(3), Number(3))
  assert_eq(codec.from_json("x"), Text("x"))
  assert_eq(codec.to_json(Number(3)), Json(3))
  assert_eq(codec.to_json(Text("x")), Json("x"))
  try {
    let _ = codec.from_json(false)
    fail("no case matched")
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) =>
      assert_eq(issues.length(), 2)
    error => raise error
  }
  let fail_codec : @schema.JsonCodec[Int32] = @schema.JsonCodec::new(
    _ => raise @schema.DecodeFailure(kind=Malformed, message="bad"),
    v => Json(v),
    @schema.Schema::of({}),
  )
  let failed = @schema.any_of("Bad", [
    @schema.case_("bad", fail_codec, (n : Int32) => Some(n), n => n),
  ])
  rejects(() => failed.from_json(1))
}

///|
test "unions enforce case cardinality and unique tags at construction" {
  rejects(() => {
    @schema.tagged("Empty", "kind", ([] : Array[@schema.Case[Example]]))
  })
  rejects(() => @schema.any_of("Duplicate", [number_case(), number_case()]))
  let cases : Array[@schema.Case[Int32]] = Array::makei(64, i => {
    @schema.case_(
      i.to_string(),
      @schema.jint,
      n => if n == i { Some(n) } else { None },
      n => n,
    )
  })
  let _ = @schema.any_of("Limit", cases)
  cases.push(@schema.case_("64", @schema.jint, n => Some(n), n => n))
  rejects(() => @schema.any_of("Overflow", cases))
}

///|
fn int_field(i : Int32) -> @schema.Field[Array[Int32], Int32] {
  @schema.field(i.to_string(), @schema.jint, values => values[i])
}

///|
test "all fixed object arities preserve field order and collect missing fields" {
  let codecs = [
    @schema.object3("N3", int_field(0), int_field(1), int_field(2), (a, b, c) => {
      [a, b, c]
    }),
    @schema.object4(
      "N4",
      int_field(0),
      int_field(1),
      int_field(2),
      int_field(3),
      (a, b, c, d) => [a, b, c, d],
    ),
    @schema.object5(
      "N5",
      int_field(0),
      int_field(1),
      int_field(2),
      int_field(3),
      int_field(4),
      (a, b, c, d, e) => [a, b, c, d, e],
    ),
    @schema.object6(
      "N6",
      int_field(0),
      int_field(1),
      int_field(2),
      int_field(3),
      int_field(4),
      int_field(5),
      (a, b, c, d, e, f) => [a, b, c, d, e, f],
    ),
    @schema.object7(
      "N7",
      int_field(0),
      int_field(1),
      int_field(2),
      int_field(3),
      int_field(4),
      int_field(5),
      int_field(6),
      (a, b, c, d, e, f, g) => [a, b, c, d, e, f, g],
    ),
    @schema.object8(
      "N8",
      int_field(0),
      int_field(1),
      int_field(2),
      int_field(3),
      int_field(4),
      int_field(5),
      int_field(6),
      int_field(7),
      (a, b, c, d, e, f, g, h) => [a, b, c, d, e, f, g, h],
    ),
  ]
  for i, codec in codecs {
    let size = i + 3
    let values = Array::makei(size, i => i + 10)
    let obj : Map[String, Json] = Map([])
    for i, value in values {
      obj[i.to_string()] = Json(value)
    }
    assert_eq(codec.from_json(Json::object(obj)), values)
    assert_eq(codec.to_json(values), Json::object(obj))
    rejects(() => codec.from_json(false))
    try {
      let _ = codec.from_json({})
      fail("missing fields accepted")
    } catch {
      @schema.DecodeFailure(kind=Invalid(issues), ..) =>
        assert_eq(issues.length(), size)
      error => raise error
    }
  }
}

///|
test "form bodies retain duplicates replacement decoding and pair limits" {
  let codec = @schema.form_body(max_pairs=2)
  assert_eq(codec.decode(b"x=a+b&x=%FF"), [("x", "a b"), ("x", "�")])
  assert_eq(codec.encode([("x", "a b"), ("x", "é")]), b"x=a+b&x=%C3%A9")
  assert_eq(codec.decode(b"&x=%zz&"), [("x", "%zz")])
  rejects(() => codec.decode(b"a=1&b=2&c=3"))
  rejects(() => @schema.form_body(max_pairs=-1).decode(b""))
  assert_eq(@schema.form_body(max_pairs=0).decode(b"&&"), [])
  let pairs = "x=1&".repeat(256)
  assert_eq(@schema.form_body().decode(@utf8.encode(pairs)).length(), 256)
  rejects(() => @schema.form_body().decode(@utf8.encode(pairs + "x=1")))
  let lone = String::from_array([(0xd800).unsafe_to_char()])
  assert_eq(@schema.text_body.encode(lone), b"\xef\xbf\xbd")
  assert_eq(codec.encode([("x", lone)]), b"x=%EF%BF%BD")
}

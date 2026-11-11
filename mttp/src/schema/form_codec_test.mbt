///|
/// A codec that hands back the JSON object the form decoder built.
fn form_probe(
  json : Json,
  defs~ : Map[String, Json] = {},
) -> @schema.BodyCodec[Json] {
  @schema.form_codec(
    @schema.JsonCodec::new(j => j, j => j, @schema.Schema::{
      name: None,
      json,
      defs,
      problems: [],
    }),
  )
}

///|
fn form_issues(
  codec : @schema.BodyCodec[Json],
  body : String,
) -> Array[@schema.Issue] raise {
  try codec.decode(@utf8.encode(body)) catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) => issues
    error => fail("unexpected failure \{error}")
  } noraise {
    j => fail("decoded \{j.stringify()}")
  }
}

///|
test "form values are coerced by their property types" {
  let codec = form_probe({
    "type": "object",
    "properties": {
      "i": { "type": "integer" },
      "n": { "type": "number" },
      "b": { "type": "boolean" },
      "s": { "type": "string" },
      "xs": { "type": "array", "items": { "type": "integer" } },
      "any": { "type": "array" },
      "u": {},
      "z": { "type": "null" },
      "t": true,
      "same": {
        "anyOf": [
          { "type": "integer" },
          { "type": "null" },
          { "type": "integer" },
        ],
      },
    },
  })
  assert_eq(codec.media_type(), "application/x-www-form-urlencoded")
  assert_eq(codec.schema().problems, [])
  let j = codec.decode(
    b"i=%2B007&n=.5&b=on&s=a+b&xs=-0&xs=12&any=1&any=x&u=7&z=&t=1&same=4&extra=1&rep=a&rep=b",
  )
  assert_eq(j, {
    "i": Json::number(7, repr="7"),
    "n": 0.5,
    "b": true,
    "s": "a b",
    "xs": [Json::number(0, repr="-0"), Json::number(12, repr="12")],
    "any": ["1", "x"],
    "u": "7",
    "z": "",
    "t": "1",
    "same": Json::number(4, repr="4"),
    "extra": "1",
    "rep": ["a", "b"],
  })
  assert_eq(codec.decode(b"b=false"), { "b": false })
  assert_eq(codec.decode(b"b=true"), { "b": true })
}

///|
test "form coercion failures and repeated scalars are issues at their pointers" {
  let codec = form_probe({
    "type": "object",
    "properties": {
      "i": { "type": "integer" },
      "n": { "type": "number" },
      "b": { "type": "boolean" },
      "a/b": { "type": "string" },
      "xs": { "type": "array", "items": { "type": "integer" } },
    },
  })
  assert_eq(
    form_issues(codec, "i=1.5&n=1e&b=yes&a%2Fb=1&a%2Fb=2&xs=1&xs=x").map(i => {
      (i.path, i.code, i.message)
    }),
    [
      ("/i", "type", "expected integer"),
      ("/n", "type", "expected number"),
      ("/b", "type", "expected true, false or on"),
      ("/a~1b", "multiple", "expected one value, got 2"),
      ("/xs/1", "type", "expected integer"),
    ],
  )
}

///|
test "absent checkboxes and lists of required properties take their empty value" {
  let codec = form_probe({
    "type": "object",
    "properties": {
      "agree": { "type": "boolean" },
      "tags": { "type": "array", "items": { "type": "string" } },
      "name": { "type": "string" },
      "maybe": { "anyOf": [{ "type": "boolean" }, { "type": "null" }] },
      "age": { "anyOf": [{ "type": "integer" }, { "type": "null" }] },
      "count": { "type": "integer" },
    },
    "required": ["agree", "tags", "name", "count"],
  })
  // Required strings and integers stay absent, so the codec reports them.
  assert_eq(codec.decode(b""), { "agree": false, "tags": [] })
  // A blank optional number is absent; a blank required one is an issue.
  assert_eq(codec.decode(b"age=&maybe=&name="), {
    "name": "",
    "agree": false,
    "tags": [],
  })
  assert_eq(form_issues(codec, "count=").map(i => i.path), ["/count"])
}

///|
test "typed form bodies decode through the object codec and its validation" {
  let codec = @schema.object4(
    "Signup",
    @schema.field("name", @schema.jstring.validate(@schema.max_length(3)), (
      s : (String, Int32, Int64, Double?),
    ) => s.0),
    @schema.field("count", @schema.jint, s => s.1),
    @schema.field("big", @schema.jint64, s => s.2),
    @schema.field("ratio", @schema.option(@schema.jdouble), s => s.3),
    (a, b, c, d) => (a, b, c, d),
  )
  let form = @schema.form_codec(codec)
  let value = ("ann", 3, 9007199254740993L, Some(0.25))
  let bytes = form.encode(value)
  assert_eq(bytes, b"name=ann&count=3&big=9007199254740993&ratio=0.25")
  assert_eq(form.decode(bytes), value)
  assert_eq(form.decode(b"name=ann&count=3&big=1&ratio="), ("ann", 3, 1L, None))
  let failure = try form.decode(b"name=long&count=x&big=1&ratio=1e999") catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) => issues
    _ => []
  } noraise {
    _ => []
  }
  // The coercion issue at /count is not repeated by jint; name and ratio
  // fail in the codec, with the issues a JSON body would have.
  assert_eq(failure.map(i => (i.path, i.code)), [
    ("/count", "type"),
    ("/ratio", "type"),
    ("/name", "constraint"),
  ])
  let json = try
    codec
    .body()
    .decode(b"{\"name\":\"long\",\"count\":3,\"big\":1,\"ratio\":null}")
  catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) => issues
    _ => []
  } noraise {
    _ => []
  }
  assert_eq(json, failure.filter(i => i.path == "/name"))
}

///|
test "form bodies keep the form pair bound and the codec's other failures" {
  let codec = form_probe({ "type": "object" })
  let pairs = "x=1&".repeat(256)
  guard codec.decode(@utf8.encode(pairs)) is { "x": Array(xs), .. } else {
    fail("x is not repeated")
  }
  assert_eq(xs.length(), 256)
  try codec.decode(@utf8.encode(pairs + "y=1")) catch {
    @schema.DecodeFailure(kind=TooLarge(limit=256), ..) => ()
    error => fail("unexpected \{error}")
  } noraise {
    _ => fail("257 pairs decoded")
  }
  let refusing = @schema.form_codec(
    @schema.JsonCodec::new(
      _ => raise @schema.DecodeFailure(kind=Malformed, message="refused"),
      (_ : Unit) => Json::object({}),
      @schema.Schema::of({ "type": "object" }),
    ),
  )
  try refusing.decode(b"a=1") catch {
    @schema.DecodeFailure(kind=Malformed, message~) =>
      assert_eq(message, "refused")
    error => fail("unexpected \{error}")
  } noraise {
    _ => fail("refusing codec decoded")
  }
}

///|
test "form encoding writes scalars as text and arrays as repeated names" {
  let codec = form_probe({ "type": "object" })
  assert_eq(
    codec.encode({
      "s": "a b&c",
      "n": 1.5,
      "t": true,
      "gone": Json::null(),
      "xs": [1, "two", Json::null()],
      "o": { "k": 1 },
    }),
    b"s=a+b%26c&n=1.5&t=true&xs=1&xs=two&o=%7B%22k%22%3A1%7D",
  )
  assert_eq(codec.encode(Json::array([])), b"")
}

///|
test "form codecs record definition problems for non-scalar properties" {
  let defs : Map[String, Json] = {
    "Point": { "type": "object", "properties": { "x": { "type": "integer" } } },
    "Loop": { "anyOf": [{ "$ref": "#/components/schemas/Loop" }] },
    "a/b~": { "type": "string" },
  }
  let codec = form_probe(
    {
      "type": "object",
      "properties": {
        "point": { "$ref": "#/components/schemas/Point" },
        "points": {
          "type": "array",
          "items": { "$ref": "#/components/schemas/Point" },
        },
        "loop": { "$ref": "#/components/schemas/Loop" },
        "gone": { "$ref": "#/components/schemas/Gone" },
        "mixed": { "anyOf": [{ "type": "integer" }, { "type": "string" }] },
        "union": { "oneOf": [{ "type": "integer" }, { "type": "object" }] },
        "nullable": { "type": ["integer", "null"] },
        "escaped": { "$ref": "#/components/schemas/a~1b~0" },
      },
    },
    defs~,
  )
  assert_eq(codec.schema().problems, [
    "form_codec property point is not a scalar or an array of scalars", "form_codec property points is not an array of scalars",
    "form_codec property loop nests references too deeply", "form_codec property gone refers to an unknown definition #/components/schemas/Gone",
    "form_codec property mixed mixes value types", "form_codec property union is not a scalar or an array of scalars",
  ])
  assert_eq(codec.decode(b"nullable=2&escaped=x"), {
    "nullable": Json::number(2, repr="2"),
    "escaped": "x",
  })
  assert_eq(@schema.form_codec(@schema.jint).schema().problems, [
    "form_codec needs an object schema",
  ])
  let named = @schema.object1(
    "Holder",
    @schema.field(
      "point",
      @schema.object1("Inner", @schema.field("x", @schema.jint, x => x), x => x),
      x => x,
    ),
    x => x,
  )
  let schema = @schema.form_codec(named).schema()
  assert_eq(schema.problems, [
    "form_codec property point is not a scalar or an array of scalars",
  ])
  assert_eq(schema.json, named.schema().json)
}

///|
test "a nullable array keeps its item schema" {
  let codec = form_probe({
    "type": "object",
    "properties": {
      "xs": { "type": ["array", "null"], "items": { "type": "integer" } },
    },
  })
  assert_eq(codec.schema().problems, [])
  assert_eq(codec.decode(b"xs=1&xs=2"), {
    "xs": [Json::number(1, repr="1"), Json::number(2, repr="2")],
  })
  let objects = form_probe({
    "type": "object",
    "properties": {
      "points": { "type": ["array", "null"], "items": { "type": "object" } },
    },
  })
  assert_eq(objects.schema().problems, [
    "form_codec property points is not an array of scalars",
  ])
  // A malformed type list says nothing about the value, so it stays text.
  let odd = form_probe({
    "type": "object",
    "properties": { "odd": { "type": [true] } },
  })
  assert_eq(odd.schema().problems, [])
  assert_eq(odd.decode(b"odd=07"), { "odd": "07" })
}

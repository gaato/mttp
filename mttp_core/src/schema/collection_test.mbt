///|
struct Tree {
  children : Array[Tree]
}

///|
test "optional fields distinguish absence from explicit null" {
  let codec : @schema.JsonCodec[(Int32?, @jsonkit.Presence[String])] = @schema.object2(
    "Optional",
    @schema.field("a", @schema.option(@schema.jint), v => v.0),
    @schema.field("b", @schema.presence(@schema.jstring), v => v.1),
    (a, b) => (a, b),
  )
  assert_eq(codec.from_json({}), (None, @jsonkit.Absent))
  assert_eq(codec.from_json({ "a": null, "b": null }), (None, @jsonkit.Null))
  assert_eq(
    codec.from_json({ "a": 1, "b": "x" }),
    (Some(1), @jsonkit.Value("x")),
  )
  assert_eq(codec.to_json((None, @jsonkit.Absent)), Json::empty_object())
  assert_eq(codec.to_json((None, @jsonkit.Null)), { "b": null })
  assert_eq(codec.to_json((Some(1), @jsonkit.Value("x"))), { "a": 1, "b": "x" })
  assert_eq(property(codec.schema().json, "required"), Some(Json::array([])))
  assert_eq(@schema.option(@schema.jint).to_json(None), Json::null())
  assert_eq(
    @schema.presence(@schema.jint).to_json(@jsonkit.Absent),
    Json::null(),
  )
  rejects(() => codec.from_json({ "a": "bad", "b": false }))
  let required = @schema.object1(
    "Required",
    @schema.field(
      "a",
      @schema.option(@schema.jint).validate(
        @schema.custom(v => {
          if v is None {
            Some("cannot be absent")
          } else {
            None
          }
        }),
      ),
      v => v,
    ),
    v => v,
  )
  try {
    let _ = required.from_json({})
    fail("missing validation skipped")
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) =>
      assert_eq(issues[0].path, "/a")
    error => raise error
  }
  let mapped = @schema.object1(
    "Mapped",
    @schema.field(
      "a",
      @schema.option(@schema.jint).map(v => v.unwrap_or(0), v => {
        if v == 0 {
          None
        } else {
          Some(v)
        }
      }),
      v => v,
    ),
    v => v,
  )
  assert_eq(mapped.from_json({}), 0)
  assert_eq(mapped.to_json(0), Json::empty_object())
}

///|
test "omittable fields may be absent but not null" {
  let codec : @schema.JsonCodec[(String?, Int32?)] = @schema.object2(
    "Link",
    @schema.field("url", @schema.omittable(@schema.jstring), v => v.0),
    @schema.field(
      "rank",
      @schema.omittable(@schema.option(@schema.jint)).map(
        v => v.unwrap_or(None),
        v => if v is None { None } else { Some(v) },
      ),
      v => v.1,
    ),
    (url, rank) => (url, rank),
  )
  assert_eq(codec.from_json({}), (None, None))
  assert_eq(
    codec.from_json({ "url": "https://a.test" }),
    (Some("https://a.test"), None),
  )
  // The child decides about null: jstring refuses it, option(jint) takes it.
  assert_eq(codec.from_json({ "rank": null }), (None, None))
  try {
    let _ = codec.from_json({ "url": null })
    fail("null accepted")
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) =>
      assert_eq(issues.map(i => (i.path, i.code, i.message)), [
        ("/url", "type", "expected string"),
      ])
    error => raise error
  }
  assert_eq(codec.to_json((None, None)), Json::empty_object())
  assert_eq(codec.to_json((Some("https://a.test"), Some(2))), {
    "url": "https://a.test",
    "rank": 2,
  })
  // The schema is the child's, not nullable, and the field is optional.
  let schema = codec.schema().json
  assert_eq(property(schema, "required"), Some(Json::array([])))
  assert_eq(
    property(schema, "properties").bind(p => property(p, "url")),
    Some(@schema.jstring.schema().json),
  )
  // Outside an object None has no JSON form: it encodes as null, like
  // option, and that null does not decode back.
  let alone = @schema.omittable(@schema.jint)
  assert_eq(alone.to_json(None), Json::null())
  assert_eq(alone.to_json(Some(1)), Json::number(1))
  assert_eq(alone.from_json(Json::number(1)), Some(1))
  rejects(() => alone.from_json(Json::null()))
}

///|
test "maps retain null values and collect all custom decoder paths" {
  let codec = @schema.map_of(@schema.option(@schema.jint))
  assert_eq(
    codec.from_json({ "x": null, "y": 1 }),
    Map([("x", None), ("y", Some(1))]),
  )
  assert_eq(codec.to_json(Map([("x", None)])), { "x": null })
  rejects(() => codec.from_json([]))
  try {
    let _ = codec.from_json({ "a/b": "x", "c~": false })
    fail("invalid values accepted")
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) =>
      assert_eq(issues.map(i => i.path), ["/a~1b", "/c~0"])
    error => raise error
  }
  let custom = @schema.JsonCodec::new(
    _ => raise @schema.DecodeFailure(kind=Malformed, message="bad"),
    (_ : Int32) => Json(1),
    @schema.Schema::of({}),
  )
  rejects(() => @schema.map_of(custom).from_json({ "a": 1 }))
  rejects(() => @schema.array(custom).from_json([1]))
  rejects(() => {
    @schema.object1("C", @schema.field("x", custom, v => v), v => v).from_json({
      "x": 1,
    })
  })
  assert_eq(custom.to_json(2), Json(1))
  let relative = @schema.JsonCodec::new(
    _ => {
      raise @schema.DecodeFailure(
        kind=Invalid([{ path: "/inner", code: "custom", message: "bad", }]),
        message="bad",
      )
    },
    (_ : Int32) => Json(1),
    @schema.Schema::of({}),
  )
  try {
    let _ = @schema.array(relative).from_json([1])
    fail("custom decoder accepted input")
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) =>
      assert_eq(issues[0].path, "/0/inner")
    error => raise error
  }
  let mapped = @schema.jint.map(
    _ => {
      raise @schema.DecodeFailure(
        kind=Invalid([{ path: "/mapped", code: "custom", message: "bad", }]),
        message="bad",
      )
    },
    (_ : Int32) => 1,
  )
  try {
    let _ = @schema.array(mapped).from_json([1])
    fail("mapping accepted input")
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) =>
      assert_eq(issues[0].path, "/0/mapped")
    error => raise error
  }
}

///|
test "recursive codecs reference themselves and restore depth after failure" {
  let codec : @schema.JsonCodec[Tree] = @schema.recursive(
    "Tree",
    self => {
      @schema.object1(
        "Tree",
        @schema.field("children", @schema.array(self), t => t.children),
        children => Tree::{ children, },
      )
    },
    max_depth=3,
  )
  let at_limit : Json = { "children": [{ "children": [{ "children": [] }] }] }
  let tree = codec.from_json(at_limit)
  assert_eq(tree.children[0].children.length(), 1)
  assert_eq(codec.to_json(tree), at_limit)
  rejects(() => codec.from_json({ "children": [at_limit] }))
  assert_eq(codec.from_json(at_limit).children.length(), 1)
  let defs : Map[String, Json] = Map([])
  assert_eq(codec.schema().reference(defs), {
    "$ref": "#/components/schemas/Tree",
  })
  assert_eq(
    defs.get("Tree"),
    Some({
      "type": "object",
      "required": ["children"],
      "properties": {
        "children": {
          "type": "array",
          "items": { "$ref": "#/components/schemas/Tree" },
        },
      },
    }),
  )
  let checked = Ref(false)
  let _ : @schema.JsonCodec[Int32] = @schema.recursive("Early", self => {
    try {
      let _ = self.from_json(0)
    } catch {
      _ => checked.val = true
    }
    @schema.jint
  })
  assert_true(checked.val)
  let default_codec : @schema.JsonCodec[Tree] = @schema.recursive(
    "DefaultTree",
    self => {
      @schema.object1(
        "DefaultTree",
        @schema.field("children", @schema.array(self), t => t.children),
        children => Tree::{ children, },
      )
    },
  )
  let mut nested : Json = { "children": [] }
  for _ in 1..<128 {
    nested = { "children": [nested] }
  }
  let _ = default_codec.from_json(nested)
  rejects(() => default_codec.from_json({ "children": [nested] }))
}

///|
/// An expression tree whose two shapes share the `left` field, so an
/// untagged union decodes `left` once per case it tries.
#derive(Eq, Debug)
enum Expr {
  Leaf(Int32)
  Pair(Expr, Int32)
  Triple(Expr, Int32, Int32)
}

///|
fn expr_codec(max_depth~ : Int32 = 128) -> @schema.JsonCodec[Expr] {
  @schema.recursive(
    "Expr",
    self => {
      let pair : @schema.JsonCodec[(Expr, Int32)] = @schema.object2(
        "Pair",
        @schema.field("left", self, p => p.0),
        @schema.field("right", @schema.jint, p => p.1),
        (l, r) => (l, r),
      )
      let triple : @schema.JsonCodec[(Expr, Int32, Int32)] = @schema.object3(
        "Triple",
        @schema.field("left", self, t => t.0),
        @schema.field("right", @schema.jint, t => t.1),
        @schema.field("extra", @schema.jint, t => t.2),
        (l, r, e) => (l, r, e),
      )
      @schema.any_of("Expr", [
        @schema.case_(
          "leaf",
          @schema.jint,
          e => if e is Leaf(n) { Some(n) } else { None },
          n => Leaf(n),
        ),
        @schema.case_(
          "triple",
          triple,
          e => if e is Triple(l, r, x) { Some((l, r, x)) } else { None },
          t => Triple(t.0, t.1, t.2),
        ),
        @schema.case_(
          "pair",
          pair,
          e => if e is Pair(l, r) { Some((l, r)) } else { None },
          p => Pair(p.0, p.1),
        ),
      ])
    },
    max_depth~,
  )
}

///|
/// `{"left": ... {"left": 0, "right": 1} ..., "right": 1}`, `depth` levels.
fn nested_pairs(depth : Int32) -> Json {
  let mut j : Json = 0
  for _ in 0..<depth {
    j = { "left": j, "right": 1 }
  }
  j
}

///|
test "untagged unions that retry a deep subtree stop at the step budget" {
  let codec = expr_codec()
  // Each level tries `triple` (decoding `left`, then failing on `extra`)
  // before `pair`, so the work doubles per level: 2^40 without the budget.
  let deep = nested_pairs(40)
  try {
    let _ = codec.from_json(deep)
    fail("exponential decoding finished")
  } catch {
    @schema.DecodeFailure(kind=TooLarge(limit~), ..) =>
      // 256 steps for each of the 81 values of the input.
      assert_eq(limit, 81 * 256)
    error => raise error
  }
  // Shallow input of the same shape decodes within the default budget.
  assert_eq(
    codec.from_json(nested_pairs(3)),
    Pair(Pair(Pair(Leaf(0), 1), 1), 1),
  )
  // The same decode through a body codec has the same bound.
  let body = codec.body()
  try {
    let _ = body.decode(@utf8.encode(deep.stringify()))
    fail("exponential body decoding finished")
  } catch {
    @schema.DecodeFailure(kind=TooLarge(..), ..) => ()
    error => raise error
  }
}

///|
test "max_steps takes exactly that many codec applications" {
  // array(option(jint)) over three values: the array, three options and
  // three integers, seven steps.
  let codec = @schema.array(@schema.option(@schema.jint))
  let input : Json = [1, null, 3]
  assert_eq(codec.from_json(input, max_steps=7), [Some(1), None, Some(3)])
  try {
    let _ = codec.from_json([1, 2, 3], max_steps=6)
    fail("decoded past the budget")
  } catch {
    @schema.DecodeFailure(kind=TooLarge(limit~), ..) => assert_eq(limit, 6)
    error => raise error
  }
  // An exhausted budget is not reported as one issue per remaining element.
  try {
    let _ = codec.from_json(Json::array(Array::make(100, Json(1))), max_steps=3)
    fail("decoded past the budget")
  } catch {
    @schema.DecodeFailure(kind=TooLarge(limit=3), ..) => ()
    error => raise error
  }
  // The body codec passes its budget on; non-positive budgets count as 1.
  try {
    let _ = codec.body(max_steps=0).decode(b"[]")
    let _ = codec.body(max_steps=1).decode(b"[1]")
    fail("decoded past the budget")
  } catch {
    @schema.DecodeFailure(kind=TooLarge(limit=1), ..) => ()
    error => raise error
  }
}

///|
test "the default budget admits large honest inputs" {
  // 4096 is the floor of the default; 256 per value covers deep layering.
  let small = @schema.array(@schema.jint)
  assert_eq(small.from_json([]), [])
  let values = Array::makei(20000, i => Json(i))
  let layered = @schema.array(
    @schema.option(@schema.option(@schema.option(@schema.jint))),
  )
  assert_eq(layered.from_json(Json::array(values)).length(), 20000)
  let text = Json::array(values).stringify()
  assert_eq(layered.body().decode(@utf8.encode(text)).length(), 20000)
}

///|
test "recursive depth issues keep their path inside unions" {
  let codec = expr_codec(max_depth=2)
  try {
    let _ = codec.from_json(nested_pairs(3))
    fail("decoded past the recursion depth")
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) =>
      assert_true(
        issues.iter().any(i => i.code == "depth" && i.path == "/left/left"),
      )
    error => raise error
  }
}

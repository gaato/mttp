///|
#derive(Eq, Debug)
enum OpenTaggedValue {
  Known(Int32)
  Other(Json)
}

///|
fn open_tagged_codec(count~ : Int32 = 1) -> @schema.JsonCodec[OpenTaggedValue] {
  let payload = @schema.object1(
    "OpenPayload",
    @schema.field("n", @schema.jint, x => x),
    x => x,
  )
  @schema.tagged(
    "OpenTagged",
    "kind/type",
    Array::makei(count, i => {
      @schema.case_(
        i.to_string(),
        payload,
        value => {
          match value {
            Known(n) => Some(n)
            _ => None
          }
        },
        n => Known(n),
      )
    }),
    unknown=@schema.jvalue.map(json => Other(json), value => {
      match value {
        Other(json) => json
        _ => abort("known projections cover Known")
      }
    }),
  )
}

///|
test "unknown tagged codecs retain validation pointers mappings and the shared budget" {
  let codec = open_tagged_codec()
  let future : Json = { "kind/type": "future", "n": "anything" }
  assert_eq(codec.from_json(future), Other(future))
  assert_eq(codec.to_json(Other(future)), future)
  assert_eq(codec.from_json({ "kind/type": "0", "n": 1 }), Known(1))
  assert_eq(codec.to_json(Known(1)), { "kind/type": "0", "n": 1 })
  let parent = @schema.object1(
    "OpenParent",
    @schema.field("event", codec, x => x),
    x => x,
  )
  let issues = try {
    ignore(parent.from_json({ "event": {} }))
    []
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) => issues
    other => fail("unexpected: \{other}")
  }
  assert_eq(issues.map(issue => issue.path), ["/event/kind~1type"])
  let issues = try {
    ignore(codec.from_json({ "kind/type": "0", "n": false }))
    []
  } catch {
    @schema.DecodeFailure(kind=Invalid(issues), ..) => issues
    other => fail("unexpected: \{other}")
  }
  assert_eq(issues, [@schema.Issue::new("type", "expected integer", path="/n")])
  for input in [future, { "kind/type": "0", "n": 1 }] {
    let stopped = try {
      ignore(codec.from_json(input, max_steps=1))
      false
    } catch {
      @schema.DecodeFailure(kind=TooLarge(limit=1), ..) => true
      _ => false
    }
    assert_true(stopped)
  }
  assert_eq(codec.from_json(future, max_steps=2), Other(future))
  assert_eq(codec.schema().problems, [])
}

///|
test "unknown tagged alternative admits the exact union case bound and rejects one past" {
  assert_eq(open_tagged_codec(count=63).schema().problems, [])
  assert_true(
    open_tagged_codec(count=64).schema().problems.any(problem => {
      problem.contains("65 cases")
    }),
  )
}

///|
test "raw URLs reject controls before normalization" {
  for c in 0..<=32 {
    let raw = "https://example.test/a" + c.unsafe_to_char().to_string() + "b"
    let refused = try {
      @model.validate_url(raw)
      false
    } catch {
      _ => true
    }
    assert_true(refused)
  }
  let refused = try {
    @model.validate_url("/a\u007fb")
    false
  } catch {
    _ => true
  }
  assert_true(refused)
  @model.validate_url("https://example.test/日本?q=%20")
}

///|
test "headers validate empty names tokens and control values" {
  for
    (name, value) in [
      ("", "x"),
      ("a b", "x"),
      ("a:b", "x"),
      ("x", "a\r\nb"),
      ("x", "\u0000"),
      ("x", "日本"),
    ] {
    let refused = try {
      @model.Headers::of([(name, value)]).validate()
      false
    } catch {
      _ => true
    }
    assert_true(refused)
  }
  @model.Headers::of([("X!", "a\tb"), ("x", "é")]).validate()
}

///|
test "headers are immutable and set keeps the first position" {
  let original = @model.Headers::of([("x", "1"), ("y", "2"), ("X", "3")])
  let changed = original.set("X", "4").add("z", "5").remove("y")
  assert_eq(original.get_all("x"), ["1", "3"])
  assert_eq(changed.iter().to_array(), [("x", "4"), ("z", "5")])
}

///|
test "attribute identities and persistent maps" {
  let a : @model.AttributeKey[Int32] = @model.AttributeKey::new("same")
  let b : @model.AttributeKey[String] = @model.AttributeKey::new("same")
  let empty = @model.Attributes::empty()
  let first = empty.put(a, 1).put(b, "text")
  let second = first.put(a, 2)
  assert_eq(a.name(), "same")
  assert_eq(empty.get(a), None)
  assert_eq(first.get(a), Some(1))
  assert_eq(
    empty.put(@model.remote_addr, "127.0.0.1").get(@model.remote_addr),
    Some("127.0.0.1"),
  )
  assert_eq(first.get(b), Some("text"))
  assert_eq(second.get(a), Some(2))
  assert_eq(first.get(a), Some(1))
}

///|
test "connection close examines repeated fields and comma tokens" {
  let response = @model.Response::new(
    200,
    headers=@model.Headers::of([
      ("connection", "keep-alive"),
      ("connection", "upgrade, CLOSE"),
    ]),
  )
  assert_true(response.closes_connection())
  assert_false(@model.Response::new(200).closes_connection())
}

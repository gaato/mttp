///|
test "form decoding preserves duplicates and uses forgiving percent decoding" {
  assert_eq(
    @model.form_urldecode(
      "a=1&a=2&&bare&=value&x=a+b%2Bc&bad=%FF%zz%&equals=a=b",
    ),
    [
      ("a", "1"),
      ("a", "2"),
      ("bare", ""),
      ("", "value"),
      ("x", "a b+c"),
      ("bad", "�%zz%"),
      ("equals", "a=b"),
    ],
  )
  let pairs = [("日本", "a b&c"), ("", ""), ("a", "+%")]
  assert_eq(@model.form_urldecode(@model.form_urlencode(pairs)), pairs)
}

///|
test "form pair limit accepts exact bounds and defaults to 256" {
  let exact = Array::make(256, "a=b").join("&")
  assert_eq(@model.form_urldecode(exact).length(), 256)
  assert_eq(@model.form_urldecode("&&", max_pairs=0), [])
  assert_eq(@model.form_urldecode("a=b", max_pairs=1), [("a", "b")])
  for case in [(exact + "&x=y", 256), ("x=y", 0)] {
    let (input, limit) = case
    try @model.form_urldecode(input, max_pairs=limit) catch {
      @model.TransportError(kind=TooLarge(limit=actual), ..) =>
        assert_eq(actual, limit)
      _ => fail("wrong limit error")
    } noraise {
      _ => fail("accepted overflow")
    }
  }
  try @model.form_urldecode("", max_pairs=-1) catch {
    @model.TransportError(kind=Invalid, ..) => ()
    _ => fail("wrong negative limit error")
  } noraise {
    _ => fail("accepted negative bound")
  }
}

///|
test "decimal_from_string rounds to three digits, ties to even" {
  let cases = [
    ("1.5", Some(1500L)),
    ("-0.0015", Some(-2L)),
    ("0.0025", Some(2L)),
    ("0.00251", Some(3L)),
    ("0.0035", Some(4L)),
    ("9.9995", Some(10000L)),
    ("999999999999.999", Some(999_999_999_999_999L)),
    ("999999999999.9996", None),
    ("00000000000000.1", Some(100L)),
    ("10000000000000.0", None),
    ("1.2x", None),
    ("09999999999999.0", None),
    ("1000000000000", None),
    ("1.", None),
    (".5", None),
    ("1e3", None),
    ("", None),
  ]
  for case in cases {
    assert_eq(@sf.decimal_from_string(case.0), case.1)
  }
}

///|
test "field lines join with a comma, and a character past ASCII fails" {
  assert_eq(
    @sf.parse_list(["1", "2"]),
    Some([Item(@sf.Item::of(Integer(1))), Item(@sf.Item::of(Integer(2)))]),
  )
  assert_eq(@sf.parse_list([]), Some([]))
  assert_eq(@sf.parse_list(["  "]), Some([]))
  assert_eq(@sf.parse_item(["\"é\""]), None)
  assert_eq(@sf.parse_item([""]), None)
  assert_eq(@sf.parse_list(["1,"]), None)
  assert_eq(@sf.parse_list(["1 2"]), None)
}

///|
test "a repeated key keeps its first place and its last value" {
  assert_eq(
    @sf.parse_dictionary(["a=1, b=2, a=3;x"]),
    Some([
      ("a", Item({ value: Integer(3), params: [("x", Boolean(true))], })),
      ("b", Item(@sf.Item::of(Integer(2)))),
    ]),
  )
  assert_eq(
    @sf.parse_item(["1;a=1;b;a=2"]).map(item => item.params),
    Some([("a", Integer(2)), ("b", Boolean(true))]),
  )
}

///|
test "each bare item parses and serializes back" {
  let cases : Array[(String, @sf.BareItem)] = [
    ("42", Integer(42)),
    ("-999999999999999", Integer(-999_999_999_999_999L)),
    ("4.5", Decimal(4500)),
    ("-0.25", Decimal(-250)),
    ("\"a \\\"q\\\" \\\\\"", String("a \"q\" \\")),
    ("*foo:bar/baz", Token("*foo:bar/baz")),
    (":aGVsbG8=:", Bytes(b"hello")),
    ("?0", Boolean(false)),
    ("@1659578233", Date(1659578233)),
    ("%\"f%c3%bc%25\"", DisplayString("fü%")),
  ]
  for case in cases {
    let (text, value) = case
    assert_eq(@sf.parse_item([text]), Some(@sf.Item::of(value)))
    assert_eq(@sf.serialize_bare_item(value), Some(text))
  }
}

///|
test "parsing fails where RFC 9651 section 4.2 fails" {
  for
    text in [
      "1234567890123456", "1234567890123.0", "1.2345", "1.", "-", "\"a", "\"\\a\"",
      ":aGVsbG8:x", ":a=b:", "?2", "@1.5", "%\"%C3%BC\"", "%\"%ff\"", "a=1", "(1 2",
      "1;A=1",
    ] {
    assert_eq(@sf.parse_item([text]), None)
  }
}

///|
test "serializing fails for what the field syntax cannot carry" {
  assert_eq(@sf.serialize_bare_item(Integer(1_000_000_000_000_000L)), None)
  assert_eq(@sf.serialize_bare_item(Decimal(1_000_000_000_000_000L)), None)
  assert_eq(@sf.serialize_bare_item(Date(-1_000_000_000_000_000L)), None)
  assert_eq(@sf.serialize_bare_item(String("tab\there")), None)
  assert_eq(@sf.serialize_bare_item(Token("1abc")), None)
  assert_eq(@sf.serialize_bare_item(Token("a b")), None)
  assert_eq(@sf.serialize_bare_item(Token("")), None)
  assert_eq(
    @sf.serialize_item({ value: Integer(1), params: [("A", Boolean(true))], }),
    None,
  )
  assert_eq(
    @sf.serialize_dictionary([("", Item(@sf.Item::of(Integer(1))))]),
    None,
  )
  assert_eq(
    @sf.serialize_dictionary([
      ("a", Item({ value: Boolean(true), params: [("A", Boolean(true))], })),
    ]),
    None,
  )
  assert_eq(@sf.serialize_list([]), Some(""))
  assert_eq(@sf.serialize_bare_item(Decimal(1000)), Some("1.0"))
  assert_eq(@sf.serialize_bare_item(Decimal(-1250)), Some("-1.25"))
  // A lone surrogate, the first half of U+1F600.
  let half = StringBuilder()
  half.write_char((0xD83D).unsafe_to_char())
  let half = half.to_string()
  assert_eq(half.length(), 1)
  assert_eq(@sf.serialize_bare_item(DisplayString(half)), None)
  assert_eq(
    @sf.serialize_bare_item(DisplayString("\u{1F600}")),
    Some("%\"%f0%9f%98%80\""),
  )
}

///|
test "a Dictionary of 8192 keys keeps each, in order" {
  let text = StringBuilder()
  for i in 0..<8192 {
    if i > 0 {
      text.write_string(", ")
    }
    text.write_string("k\{i}")
  }
  let dict = @sf.parse_dictionary([text.to_string()]).unwrap()
  assert_eq(dict.length(), 8192)
  assert_eq(dict[8191].0, "k8191")
}

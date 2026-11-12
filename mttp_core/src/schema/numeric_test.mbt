///|
/// Decodes `text` as a JSON body with `codec`, or None when refused.
fn[T] body_value(codec : @schema.JsonCodec[T], text : String) -> T? {
  try codec.body().decode(@utf8.encode(text)) catch {
    @schema.DecodeFailure(..) => None
  } noraise {
    value => Some(value)
  }
}

///|
/// Whether `jint` refuses a JSON value built in code.
fn int_refuses(j : Json) -> Bool {
  try @schema.jint.from_json(j) catch {
    @schema.DecodeFailure(..) => true
  } noraise {
    _ => false
  }
}

///|
test "jint checks the preserved lexeme for integrality and range" {
  for
    (text, value) in [
      ("2147483647", 2147483647),
      ("-2147483648", -2147483648),
      ("-2147483648.0", -2147483648),
      ("2147483647.000", 2147483647),
      ("1e0", 1),
      ("1.5e1", 15),
      ("-0", 0),
      ("-0.0e5", 0),
      ("0e999999999999", 0),
      ("21474836.47e2", 2147483647),
    ] {
    assert_eq(body_value(@schema.jint, text), Some(value), msg=text)
  }
  for
    text in [
      "2147483648", "-2147483649", "1.0000000000000001", "2147483647.0000001", "-2147483648.0000001",
      "2147483647.5", "1e10", "1e99999999999", "1.5", "1e-1", "1.5e0", "9007199254740993",
    ] {
    assert_eq(body_value(@schema.jint, text), None, msg=text)
  }
  // Without a lexeme the Double itself is checked.
  assert_eq(@schema.jint.from_json(Json::number(2147483647.0)), 2147483647)
  for value in [2147483648.0, -2147483649.0, 0.5] {
    assert_true(int_refuses(Json::number(value)), msg=value.to_string())
  }
  // A programmatic lexeme is checked as well.
  assert_true(int_refuses(Json::number(1.0, repr="1.0000000000000001")))
}

///|
test "jint64 and jdouble boundaries through a JSON body" {
  for
    (text, value) in [
      ("9223372036854775807", 9223372036854775807L),
      ("-9223372036854775808.0", -9223372036854775808L),
      ("9007199254740993", 9007199254740993L),
      ("1.5e1", 15L),
      ("-0", 0L),
    ] {
    assert_eq(body_value(@schema.jint64, text), Some(value), msg=text)
  }
  for
    text in [
      "9223372036854775808", "1.0000000000000001", "9223372036854775807.5", "1e19",
      "1e99999999999",
    ] {
    assert_eq(body_value(@schema.jint64, text), None, msg=text)
  }
  // A double is a Double: rounding is its contract, overflow is refused.
  assert_eq(body_value(@schema.jdouble, "1.0000000000000001"), Some(1.0))
  assert_eq(body_value(@schema.jdouble, "-0"), Some(-0.0))
  assert_eq(body_value(@schema.jdouble, "1.5e1"), Some(15.0))
  assert_eq(body_value(@schema.jdouble, "1e400"), None)
  assert_eq(body_value(@schema.jdouble, "-1e400"), None)
}

///|
test "validators bound the exact integer, not a rounded one" {
  let bounded = @schema.jint
    .validate(@schema.minimum(0))
    .validate(@schema.maximum(10))
  assert_eq(body_value(bounded, "10.0"), Some(10))
  assert_eq(body_value(bounded, "10.0000000000000001"), None)
  assert_eq(body_value(bounded, "-0.0000000000000001"), None)
  assert_eq(body_value(bounded, "11"), None)
}

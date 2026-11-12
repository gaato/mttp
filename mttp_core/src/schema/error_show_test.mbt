///|
test "a decoding failure interpolates as its message" {
  let failure = @schema.DecodeFailure(kind=Malformed, message="not a number")
  assert_eq("\{failure}", failure.message())
}

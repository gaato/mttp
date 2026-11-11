///|
/// Checks that `parse` gives the same value for `input` whole, split in two
/// at every offset (empty first and last pieces included) and fed one byte
/// at a time. Fold expected errors into the value to compare them too.
fn[T : Eq + Debug] check_splits(
  input : Bytes,
  parse : (Array[Bytes]) -> T raise,
) -> T raise {
  let expected = parse([input])
  for cut in 0..<=input.length() {
    assert_eq(
      parse([input[:cut].to_owned(), input[cut:].to_owned()]),
      expected,
      msg="differs when split at \{cut}",
    )
  }
  assert_eq(
    parse(Array::makei(input.length(), i => input[i:i + 1].to_owned())),
    expected,
    msg="differs when fed byte by byte",
  )
  expected
}

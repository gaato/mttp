///|
test "a failed scanner refuses both further bytes and finish" {
  let scanner = Scanner::new("B", 1, 1024, 0, 78)
  try scanner.byte(b'x') catch {
    @mttp_core.TransportError(kind=TooLarge(limit=0), phase=Body, ..) => ()
    error => raise error
  } noraise {
    _ => fail("expected total byte limit")
  }
  try scanner.byte(b'y') catch {
    @mttp_core.TransportError(kind=Protocol, phase=Body, detail="parser failed") =>
      ()
    error => raise error
  } noraise {
    _ => fail("failed scanner accepted another byte")
  }
  try scanner.finish() catch {
    @mttp_core.TransportError(kind=Protocol, phase=Body, detail="parser failed") =>
      ()
    error => raise error
  } noraise {
    _ => fail("failed scanner accepted finish")
  }
  assert_eq(scanner.total, 0)
  assert_true(scanner.failed)
}

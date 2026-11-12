///|
test "framing rejects conflicting lengths and unsupported transfer encodings" {
  for
    pair in [
      (
        [("content-length", "1"), ("transfer-encoding", "chunked")],
        @h1.ParseKind::Smuggling,
      ),
      ([("content-length", "1"), ("content-length", "1")], Malformed),
      ([("content-length", "1, 1")], Malformed),
      ([("content-length", "-1")], Malformed),
      ([("content-length", "")], Malformed),
      ([("content-length", "9223372036854775808")], Malformed),
      ([("transfer-encoding", "chunked, chunked")], Malformed),
      ([("transfer-encoding", "")], Malformed),
      ([("transfer-encoding", "gzip, chunked")], Unsupported),
    ] {
    try @h1.request_framing(@mttp_core.Headers::of(pair.0)) catch {
      @h1.ParseError(kind~, ..) => assert_eq(kind, pair.1)
    } noraise {
      _ => fail("accepted framing")
    }
  }
  assert_eq(@h1.request_framing(@mttp_core.Headers::empty()), NoBody)
  assert_eq(
    @h1.request_framing(
      @mttp_core.Headers::of([("content-length", "9223372036854775807")]),
    ),
    Length(9223372036854775807L),
  )
  assert_eq(
    @h1.request_framing(
      @mttp_core.Headers::of([("transfer-encoding", "Chunked")]),
    ),
    Chunked,
  )
  assert_eq(
    @h1.response_framing(@mttp_core.Headers::empty(), status=200),
    UntilClose,
  )
  for status in [100, 204, 304] {
    assert_eq(
      @h1.response_framing(@mttp_core.Headers::empty(), status~),
      NoBody,
    )
  }
  assert_eq(
    @h1.response_framing(@mttp_core.Headers::empty(), status=200, meth=Head),
    NoBody,
  )
  assert_eq(
    @h1.response_framing(@mttp_core.Headers::empty(), status=200, meth=Connect),
    NoBody,
  )
}

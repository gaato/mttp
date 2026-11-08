///|
test "wire writers retain duplicate fields and replace framing consistently" {
  let fields = @http.Headers::of([
    ("set-cookie", "a=1"),
    ("set-cookie", "b=2"),
    ("x", "ÿ"),
    ("content-length", "99"),
    ("transfer-encoding", "gzip"),
  ])
  for framing in [@h1.Framing::NoBody, Length(3), Chunked, UntilClose] {
    let head = @h1.write_response_head(200, fields, framing, Http11)
    let response = @h1.parse_response_head(head)
    let parsed = response.headers
    assert_eq(response.version, Http11)
    assert_eq(response.status, 200)
    assert_eq(parsed.get_all("set-cookie"), ["a=1", "b=2"])
    assert_eq(parsed.get("x"), Some("ÿ"))
    match framing {
      NoBody | UntilClose => {
        assert_eq(parsed.get("content-length"), None)
        assert_eq(parsed.get("transfer-encoding"), None)
      }
      Length(_) => assert_eq(parsed.get("content-length"), Some("3"))
      Chunked => assert_eq(parsed.get("transfer-encoding"), Some("chunked"))
      @h1.Framing::.. => fail("unexpected framing")
    }
    if framing == UntilClose {
      assert_eq(parsed.get("connection"), Some("close"))
    }
  }
  assert_eq(
    @h1.parse_response_head(
      @h1.write_response_head(204, @http.Headers::empty(), NoBody, Http10),
    ).version,
    Http10,
  )
  let request = @h1.write_request_head(
    Post,
    "/path?q=1",
    @http.Headers::of([("host", "h")]),
    Length(2),
    Http11,
  )
  let parsed = @h1.parse_request_head(request)
  assert_eq(parsed.meth, Post)
  assert_eq(parsed.target, "/path?q=1")
  assert_eq(@h1.request_framing(parsed.headers), Length(2))
  let decoder = @h1.ChunkedDecoder::new(@h1.Limits::default())
  assert_eq(decoder.feed(@h1.encode_chunk(b"data")).chunks, [b"data"])
  assert_true(decoder.feed(@h1.encode_chunk(b"")).done)
}

///|
test "writers reject invalid framing fields and request targets" {
  for framing in [@h1.Framing::Length(-1), Chunked] {
    try
      @h1.write_response_head(200, @http.Headers::empty(), framing, Http10)
    catch {
      @h1.ParseError(..) => ()
    } noraise {
      _ => fail("accepted invalid framing")
    }
  }
  for status in [99, 600, 101, 204] {
    try
      @h1.write_response_head(status, @http.Headers::empty(), Length(1), Http11)
    catch {
      @h1.ParseError(kind=Malformed, ..) => ()
      _ => fail("wrong status error")
    } noraise {
      _ => fail("accepted status")
    }
  }
  for
    pair in [
      ("bad name", "v"),
      ("x", "a\r\nb"),
      ("x", "日本"),
      ("content-length", "a\u{00}b"),
    ] {
    try
      @h1.write_response_head(200, @http.Headers::of([pair]), NoBody, Http11)
    catch {
      @h1.ParseError(kind=Malformed, ..) => ()
      _ => fail("wrong header error")
    } noraise {
      _ => fail("accepted invalid field")
    }
  }
  for framing in [@h1.Framing::NoBody, UntilClose] {
    try
      @h1.write_request_head(
        Get,
        "/bad target",
        @http.Headers::of([("host", "h")]),
        framing,
        Http11,
      )
    catch {
      @h1.ParseError(kind=Malformed, ..) => ()
      _ => fail("wrong request error")
    } noraise {
      _ => fail("accepted request")
    }
  }
}

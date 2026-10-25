///|
test "request target forms and HTTP version framing are unambiguous" {
  for
    (meth, target) in [
      ("GET", "https://h/a?b"),
      ("CONNECT", "h:443"),
      ("CONNECT", "h:80"),
      ("CONNECT", "[::1]:80"),
      ("CONNECT", "[::1]:443"),
      ("OPTIONS", "*"),
    ] {
    let parsed = @h1.parse_request_head(
      @model.encode_utf8(meth + " " + target + " HTTP/1.1\r\nHost: h\r\n\r\n"),
    )
    assert_eq(parsed.1, target)
    let written = @h1.write_request_head(
      parsed.0,
      target,
      parsed.3,
      @h1.NoBody,
      parsed.2,
    )
    assert_eq(@h1.parse_request_head(written).1, target)
  }
  for
    (meth, target) in [
      ("GET", "relative"),
      ("GET", "*"),
      ("CONNECT", "/a"),
      ("CONNECT", "h"),
      ("CONNECT", ":443"),
      ("CONNECT", "h:bad"),
      ("CONNECT", "h:"),
      ("CONNECT", "[::1]"),
      ("CONNECT", "[::1]:"),
      ("CONNECT", "h:65536"),
      ("GET", "http://h:bad/"),
      ("GET", "ftp://h/a"),
      ("GET", "http://u@h/a"),
      ("GET", "/a\\b"),
    ] {
    try
      @h1.parse_request_head(
        @model.encode_utf8(meth + " " + target + " HTTP/1.1\r\nHost: h\r\n\r\n"),
      )
    catch {
      @h1.ParseError(kind=Malformed, ..) => ()
      _ => fail("wrong target error")
    } noraise {
      _ => fail("accepted invalid target form")
    }
  }
  try
    @h1.parse_request_head(
      b"POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n",
    )
  catch {
    @h1.ParseError(kind=Malformed, ..) => ()
    _ => fail("wrong HTTP/1.0 request error")
  } noraise {
    _ => fail("accepted chunked HTTP/1.0")
  }
  try
    @h1.parse_response_head(
      b"HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
    )
  catch {
    @h1.ParseError(kind=Malformed, ..) => ()
    _ => fail("wrong HTTP/1.0 response error")
  } noraise {
    _ => fail("accepted chunked HTTP/1.0 response")
  }
}

///|
test "invalid decoder configuration and malformed split CRLF are sticky" {
  try @h1.scan_head(b"", max=-1) catch {
    @h1.ParseError(kind=Malformed, ..) => ()
    _ => fail("wrong configuration error")
  } noraise {
    _ => fail("accepted negative limit")
  }
  let negative = @h1.HeadDecoder::new(max=-1)
  try negative.feed(b"") catch {
    @h1.ParseError(kind=Malformed, ..) => ()
    _ => fail("wrong decoder error")
  } noraise {
    _ => fail("accepted negative decoder limit")
  }
  try
    @h1.parse_request_head(b"GET / HTTP/1.0\r\n\r\n", limits={
      ..@h1.Limits::default(),
      max_headers: -1,
    })
  catch {
    @h1.ParseError(kind=Malformed, ..) => ()
    _ => fail("wrong count configuration")
  } noraise {
    _ => fail("accepted negative header count")
  }
  for bytes in [b"GET / HTTP/1.1\n\n", b"GET / HTTP/1.1\rX"] {
    @testing.check_splits(bytes, chunks => {
      let decoder = @h1.HeadDecoder::new()
      try {
        for chunk in chunks {
          let _ = decoder.feed(chunk)
        }
        let _ = decoder.finish()
        None
      } catch {
        @h1.ParseError(kind~, ..) => Some(kind)
      }
    })
  }
}

///|
test "head decoding preserves fields at every split and leaves pipelined bytes" {
  let bytes = b"HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nX: \xff\t \r\n\r\nbody"
  @testing.check_splits(bytes, chunks => {
    let decoder = @h1.HeadDecoder::new()
    let rest = Buffer()
    for chunk in chunks {
      let result = decoder.feed(chunk)
      rest.write_bytes(chunk[result.consumed:])
    }
    let head = decoder.finish()
    let (version, status, headers) = @h1.parse_response_head(head)
    assert_eq(version, Http11)
    assert_eq(status, 200)
    assert_eq(headers.get_all("set-cookie"), ["a=1", "b=2"])
    assert_eq(headers.get("x"), Some("ÿ"))
    assert_eq(rest.to_bytes(), b"body")
    (head, rest.to_bytes())
  })
}

///|
test "head scanner and accumulator enforce exact byte and field limits" {
  let head = b"GET / HTTP/1.1\r\nHost: h\r\n\r\n"
  assert_eq(@h1.scan_head(head, max=head.length()), Some(head.length()))
  assert_eq(@h1.scan_head(head[:head.length() - 1], max=head.length()), None)
  let decoder = @h1.HeadDecoder::new(max=head.length())
  assert_eq(decoder.feed(head).head, Some(head))
  for max in [0, head.length() - 1] {
    try @h1.scan_head(head, max~) catch {
      @h1.ParseError(kind=HeadTooLarge, ..) => ()
      _ => fail("wrong scan limit")
    } noraise {
      _ => fail("expected scan overflow")
    }
    let d = @h1.HeadDecoder::new(max~)
    try d.feed(head) catch {
      @h1.ParseError(kind=HeadTooLarge, ..) => ()
      _ => fail("wrong feed limit")
    } noraise {
      _ => fail("expected feed overflow")
    }
    try d.feed(b"\r\n\r\n") catch {
      @h1.ParseError(kind=HeadTooLarge, ..) => ()
      _ => fail("error changed")
    } noraise {
      _ => fail("error not sticky")
    }
  }
  let limits = { ..@h1.Limits::default(), max_headers: 1, }
  let _ = @h1.parse_request_head(head, limits~)
  try
    @h1.parse_request_head(
      b"GET / HTTP/1.1\r\nHost: h\r\nX: 1\r\n\r\n",
      limits~,
    )
  catch {
    @h1.ParseError(kind=HeadTooLarge, ..) => ()
    _ => fail("wrong field count error")
  } noraise {
    _ => fail("accepted too many fields")
  }
  assert_eq(@h1.Limits::default().max_head_bytes, 16384)
  assert_eq(@h1.Limits::default().max_headers, 100)
}

///|
test "strict request heads reject ambiguous syntax and host authorities" {
  for
    head in [
      b"GET / HTTP/1.1\r\nHost: :80\r\n\r\n", b"GET / HTTP/1.1\r\n\r\n", b"GET / HTTP/1.1\r\nHost: h\r\nHost: h\r\n\r\n",
      b"GET / HTTP/1.1\r\nHost: \r\n\r\n", b"GET / HTTP/1.1\r\nHost: h/x\r\n\r\n",
      b"GET / HTTP/1.1\r\nHost: h:99999\r\n\r\n", b"GET / HTTP/1.1\r\nHost: h@x\r\n\r\n",
      b"GET  / HTTP/1.1\r\nHost: h\r\n\r\n", b"G(ET / HTTP/1.1\r\nHost: h\r\n\r\n",
      b"GET /#f HTTP/1.1\r\nHost: h\r\n\r\n", b"GET /\x00 HTTP/1.1\r\nHost: h\r\n\r\n",
      b"GET / HTTP/1.1\r\nHost : h\r\n\r\n", b"GET / HTTP/1.1\r\nHost: h\r\n folded\r\n\r\n",
      b"GET / HTTP/1.1\r\nHost: h\r\nX: a\x00b\r\n\r\n", b"GET / HTTP/1.1\nHost: h\n\n",
      b"GET / HTTP/1.1\rX: h\r\n\r\n",
    ] {
    try @h1.parse_request_head(head) catch {
      @h1.ParseError(kind=Malformed, ..) => ()
      _ => fail("wrong malformed classification")
    } noraise {
      _ => fail("accepted malformed head")
    }
  }
  assert_eq(@h1.parse_request_head(b"OPTIONS * HTTP/1.0\r\n\r\n").2, Http10)
  assert_eq(
    @h1.parse_request_head(b"GET / HTTP/1.1\r\nHost: [::1]:80\r\n\r\n").1,
    "/",
  )
}

///|
test "response start lines and incomplete streams fail deterministically" {
  for
    head in [
      b"HTTP/1.1 20 OK\r\n\r\n", b"HTTP/1.1 2x0 OK\r\n\r\n", b"HTTP/1.1 099 Bad\r\n\r\n",
      b"HTTP/1.1 600 Bad\r\n\r\n", b"HTTP/1.1 200 x\x00\r\n\r\n", b"HTTP/1.1 200 OK\r\n\r\nextra",
    ] {
    try @h1.parse_response_head(head) catch {
      @h1.ParseError(kind=Malformed, ..) => ()
      _ => fail("wrong malformed response")
    } noraise {
      _ => fail("accepted response")
    }
  }
  try @h1.parse_response_head(b"HTTP/2.0 200 OK\r\n\r\n") catch {
    @h1.ParseError(kind=Unsupported, ..) => ()
    _ => fail("wrong unsupported version")
  } noraise {
    _ => fail("accepted version")
  }
  let decoder = @h1.HeadDecoder::new()
  let _ = decoder.feed(b"HTTP/1.1 200 OK\r")
  for _ in 0..<2 {
    try decoder.finish() catch {
      @h1.ParseError(kind=Malformed, ..) => ()
      _ => fail("wrong EOF error")
    } noraise {
      _ => fail("accepted truncated head")
    }
  }
}

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
    try @h1.request_framing(@model.Headers::of(pair.0)) catch {
      @h1.ParseError(kind~, ..) => assert_eq(kind, pair.1)
    } noraise {
      _ => fail("accepted framing")
    }
  }
  assert_eq(@h1.request_framing(@model.Headers::empty()), NoBody)
  assert_eq(
    @h1.request_framing(
      @model.Headers::of([("content-length", "9223372036854775807")]),
    ),
    Length(9223372036854775807L),
  )
  assert_eq(
    @h1.request_framing(@model.Headers::of([("transfer-encoding", "Chunked")])),
    Chunked,
  )
  assert_eq(
    @h1.response_framing(@model.Headers::empty(), status=200),
    UntilClose,
  )
  for status in [100, 204, 304] {
    assert_eq(@h1.response_framing(@model.Headers::empty(), status~), NoBody)
  }
  assert_eq(
    @h1.response_framing(@model.Headers::empty(), status=200, meth=Head),
    NoBody,
  )
  assert_eq(
    @h1.response_framing(@model.Headers::empty(), status=200, meth=Connect),
    NoBody,
  )
}

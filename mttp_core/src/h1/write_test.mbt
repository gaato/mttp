///|
test "wire writers retain duplicate fields and replace framing consistently" {
  let fields = @mttp_core.Headers::of([
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
      NoBody => {
        assert_eq(parsed.get_all("content-length"), ["0"])
        assert_eq(parsed.get("transfer-encoding"), None)
      }
      UntilClose => {
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
      @h1.write_response_head(204, @mttp_core.Headers::empty(), NoBody, Http10),
    ).version,
    Http10,
  )
  let request = @h1.write_request_head(
    Post,
    "/path?q=1",
    @mttp_core.Headers::of([("host", "h")]),
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
      @h1.write_response_head(200, @mttp_core.Headers::empty(), framing, Http10)
    catch {
      @h1.ParseError(..) => ()
    } noraise {
      _ => fail("accepted invalid framing")
    }
  }
  for status in [99, 600, 101, 204] {
    try
      @h1.write_response_head(
        status,
        @mttp_core.Headers::empty(),
        Length(1),
        Http11,
      )
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
      @h1.write_response_head(
        200,
        @mttp_core.Headers::of([pair]),
        NoBody,
        Http11,
      )
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
        @mttp_core.Headers::of([("host", "h")]),
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

///|
/// What `response_framing` must read back from a head written with
/// `framing`: the same body, `Length(0)` for an empty one, and `NoBody`
/// whenever the response cannot have a body.
fn read_back(
  status : Int32,
  meth : @mttp_core.Method,
  framing : @h1.Framing,
) -> @h1.Framing {
  let no_body = meth == Head ||
    status / 100 == 1 ||
    status == 204 ||
    status == 304 ||
    (meth == Connect && status / 100 == 2)
  match framing {
    _ if no_body => NoBody
    NoBody => Length(0)
    other => other
  }
}

///|
test "every written response head reads back with the framing it was written with" {
  let framings : Array[@h1.Framing] = [
    NoBody,
    Length(0),
    Length(7),
    Chunked,
    UntilClose,
  ]
  let methods : Array[@mttp_core.Method] = [Get, Head, Post, Connect]
  for status in 100..<=599 {
    for framing in framings {
      for v in [@h1.Version::Http10, Http11] {
        for meth in methods {
          let refused = (
              (
                status / 100 == 1 ||
                status == 204 ||
                (meth == Connect && status / 100 == 2)
              ) &&
              framing != NoBody
            ) ||
            (framing == Chunked && v == Http10)
          let case = "\{status} \{@debug.to_string(framing)} \{@debug.to_string(v)} \{meth}"
          let head = @h1.write_response_head(
            status,
            @mttp_core.Headers::empty(),
            framing,
            v,
            meth~,
          ) catch {
            @h1.ParseError(..) => {
              assert_true(refused, msg="refused: \{case}")
              continue
            }
          }
          assert_false(refused, msg="accepted: \{case}")
          let response = @h1.parse_response_head(head)
          assert_eq(response.status, status, msg=case)
          assert_eq(response.version, v, msg=case)
          assert_eq(
            @h1.response_framing(response.headers, status~, meth~),
            read_back(status, meth, framing),
            msg=case,
          )
          // A response that cannot have a body carries no framing field
          // unless the caller described a GET's body (HEAD, 304).
          if framing == NoBody && read_back(status, meth, NoBody) == NoBody {
            assert_eq(response.headers.length(), 0, msg=case)
          }
        }
      }
    }
  }
}

///|
test "a written request without a body declares an empty one only when the method expects content" {
  let host = @mttp_core.Headers::of([("host", "h")])
  for meth in [@mttp_core.Method::Post, Put, Patch] {
    let head = @h1.write_request_head(meth, "/", host, NoBody, Http11)
    let parsed = @h1.parse_request_head(head)
    assert_eq(parsed.headers.get_all("content-length"), ["0"])
    assert_eq(@h1.request_framing(parsed.headers), Length(0))
  }
  for
    meth in [
      @mttp_core.Method::Get,
      Head,
      Delete,
      Options,
      Trace,
      Other("PURGE"),
    ] {
    let head = @h1.write_request_head(meth, "/", host, NoBody, Http11)
    let parsed = @h1.parse_request_head(head)
    assert_eq(parsed.headers.get("content-length"), None)
    assert_eq(@h1.request_framing(parsed.headers), NoBody)
    let head = @h1.write_request_head(meth, "/", host, Length(0), Http11)
    assert_eq(
      @h1.request_framing(@h1.parse_request_head(head).headers),
      Length(0),
    )
  }
  let connect = @h1.write_request_head(Connect, "h:443", host, NoBody, Http11)
  assert_eq(@h1.parse_request_head(connect).headers.get("content-length"), None)
  for v in [@h1.Version::Http10, Http11] {
    let head = @h1.write_request_head(Post, "/", host, NoBody, v)
    assert_eq(
      @h1.request_framing(@h1.parse_request_head(head).headers),
      Length(0),
    )
  }
}

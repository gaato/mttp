///|
test "decoded reader drains through upstream EOF and header rewrite is immutable" {
  @driver.run_sync(() => {
    let original : @model.ResponseHead = {
      status: 200,
      headers: @model.Headers::of([
        ("content-encoding", "gzip"),
        ("content-length", "29"),
      ]),
    }
    let (head, decoder) = @codings.decode_head(original)
    assert_eq(head.headers.get("content-length"), None)
    assert_eq(original.headers.get("content-length"), Some("29"))
    let chunks = [
      b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\xd7\x51\xc8\x40\xa2\x00\x9f\xa1\xca\x09\x13\x00\x00\x00",
    ]
    let cursor = Ref(0)
    let out = Buffer()
    while @codings.read_decoded(
            () => {
              let result = chunks.get(cursor.val)
              cursor.val += 1
              result
            },
            decoder,
          )
          is Some(bytes) {
      out.write_bytes(bytes)
    }
    assert_eq(out.to_bytes(), b"hello, hello, hello")
    assert_eq(cursor.val, 2)
  })
}

///|
test "public decoder rejects invalid plans before allocating stages" {
  for plan in [[], Array::make(6, @codings.Coding::Gzip)] {
    try @codings.ContentDecoder::new(plan) catch {
      @model.TransportError(kind=Invalid, phase=Body, ..) => ()
      _ => fail("wrong plan error")
    } noraise {
      _ => fail("accepted invalid plan")
    }
  }
  assert_eq(@codings.coding_plan("gzip, br"), [Brotli, Gzip])
  assert_eq(@codings.coding_plan("gzip, custom"), [])
}

///|
test "public decoder refuses input overwrite and premature EOF without losing input" {
  let decoder = @codings.ContentDecoder::new([Gzip])
  decoder.feed(b"")
  try decoder.feed(b"lost") catch {
    @model.TransportError(kind=Invalid, ..) => ()
    _ => fail("wrong overwrite error")
  } noraise {
    _ => fail("accepted overwrite")
  }
  try decoder.end() catch {
    @model.TransportError(kind=Invalid, ..) => ()
    _ => fail("wrong premature EOF error")
  } noraise {
    _ => fail("accepted premature EOF")
  }
  assert_true(decoder.pull() is NeedInput)
  decoder.end()
  decoder.end()
  assert_true(decoder.pull() is Done)
  assert_true(decoder.pull() is Done)
  try decoder.feed(b"late") catch {
    @model.TransportError(kind=Invalid, ..) => ()
    _ => fail("wrong late feed error")
  } noraise {
    _ => fail("accepted input after EOF")
  }
}

///|
test "decoder failures remain sticky on every public operation" {
  let decoder = @codings.ContentDecoder::new([Gzip])
  decoder.feed(b"\x00\x00")
  assert_true(decoder.pull() is NeedInput)
  decoder.end()
  try decoder.pull() catch {
    @model.TransportError(kind=Protocol, ..) => ()
    _ => fail("wrong malformed coding")
  } noraise {
    _ => fail("accepted corrupt gzip")
  }
  for
    operation in [
      () => {
        let _ = decoder.pull()
      },
      () => decoder.feed(b"x"),
      () => decoder.end(),
    ] {
    try operation() catch {
      @model.TransportError(kind=Protocol, ..) => ()
      _ => fail("changed error kind")
    } noraise {
      _ => fail("lost sticky failure")
    }
  }
}

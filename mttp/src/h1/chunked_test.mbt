///|
test "chunk extensions allow bounded whitespace and lowercase hexadecimal" {
  let decoder = @h1.ChunkedDecoder::new(@h1.Limits::default())
  let result = decoder.feed(
    b"a ; x = \"quoted\" ; y= value \r\n0123456789\r\n0\r\n\r\n",
  )
  assert_true(result.done)
  assert_eq(result.chunks, [b"0123456789"])
}

///|
test "chunked decoding handles every split and stops before pipelined bytes" {
  let wire = b"4;name=\"a;\\\"b\"\r\nWiki\r\n5; flag\r\npedia\r\n0\r\nX-End: 1\r\nX-End: 2\r\n\r\nNEXT"
  @testing.check_splits(wire, chunks => {
    let decoder = @h1.ChunkedDecoder::new(@h1.Limits::default())
    let body = Buffer()
    let rest = Buffer()
    let mut trailers = @model.Headers::empty()
    for bytes in chunks {
      let result = decoder.feed(bytes)
      for chunk in result.chunks {
        assert_false(chunk.is_empty())
        body.write_bytes(chunk)
      }
      rest.write_bytes(bytes[result.consumed:])
      trailers = result.trailers
    }
    decoder.finish()
    assert_eq(body.to_bytes(), b"Wikipedia")
    assert_eq(rest.to_bytes(), b"NEXT")
    assert_eq(trailers.get_all("x-end"), ["1", "2"])
    (body.to_bytes(), rest.to_bytes(), trailers)
  })
}

///|
fn refused(
  wire : Bytes,
  limits~ : @h1.Limits = @h1.Limits::default(),
  kind~ : @h1.ParseKind = Malformed,
) -> Unit raise {
  let decoder = @h1.ChunkedDecoder::new(limits)
  try {
    let _ = decoder.feed(wire)
    decoder.finish()
  } catch {
    @h1.ParseError(kind=actual, ..) => assert_eq(actual, kind)
  } noraise {
    _ => fail("accepted malformed chunk framing")
  }
  try decoder.feed(b"0\r\n\r\n") catch {
    @h1.ParseError(kind=actual, ..) => assert_eq(actual, kind)
  } noraise {
    _ => fail("failure not sticky")
  }
  try decoder.finish() catch {
    @h1.ParseError(kind=actual, ..) => assert_eq(actual, kind)
  } noraise {
    _ => fail("finish failure not sticky")
  }
}

///|
test "chunk lines trailers and field counts enforce exact limits" {
  let limits = {
    ..@h1.Limits::default(),
    max_chunk_line_bytes: 3,
    max_trailer_bytes: 8,
    max_headers: 1,
  }
  let decoder = @h1.ChunkedDecoder::new(limits)
  assert_true(decoder.feed(b"1\r\na\r\n0\r\nX: 1\r\n\r\n").done)
  decoder.finish()
  refused(b"01\r\na\r\n0\r\n\r\n", limits~)
  refused(b"0\r\nX: 12\r\n\r\n", limits~)
  refused(b"0\r\nX: 1\r\nY: 2\r\n\r\n", limits={
    ..limits,
    max_trailer_bytes: 100,
  })
  refused(b"0\r\n\r\n", limits={ ..limits, max_chunk_line_bytes: -1, })
  refused(b"0\r\n\r\n", limits={ ..limits, max_trailer_bytes: -1, })
  refused(b"0\r\n\r\n", limits={ ..limits, max_headers: -1, })
  assert_eq(@h1.Limits::default().max_chunk_line_bytes, 4096)
  assert_eq(@h1.Limits::default().max_trailer_bytes, 16384)
}

///|
test "chunk decoder rejects malformed sizes extensions delimiters and framing trailers" {
  for
    wire in [
      b"\r\n", b"x\r\n", b"-1\r\n", b"8000000000000000\r\n", b" 1\r\n", b"1 \r\n",
      b"1;\r\n", b"1;x=\r\n", b"1;x=\"no\r\n", b"1;x=\"back\\\r\n", b"1;x=\"\x00\"\r\n",
      b"1;x=\"\\\x00\"\r\n", b"1;x=@\r\n", b"1;x=ok?\r\n", b"1\na\r\n", b"1\rxa\r\n",
      b"1\r\naX", b"1\r\na\rX", b"0\r\nBad Header: 1\r\n\r\n",
    ] {
    refused(wire)
  }
  for
    name in [
      "content-length", "transfer-encoding", "host", "connection", "trailer",
    ] {
    refused(@model.encode_utf8("0\r\n" + name + ": x\r\n\r\n"), kind=Smuggling)
  }
  let wire = b"A\r\n0123456789\r\n0\r\n\r\n"
  for end in 0..<wire.length() {
    refused(wire[:end].to_owned())
  }
  let decoder = @h1.ChunkedDecoder::new(@h1.Limits::default())
  assert_true(decoder.feed(wire).done)
}

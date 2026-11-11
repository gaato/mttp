///|
/// `prefix`, then `fill` repeated until the result is `total` bytes long
/// with `suffix` at the end.
fn padded(prefix : String, total : Int32, suffix : String) -> Bytes {
  let fill = total - prefix.length() - suffix.length()
  @mttp.encode_utf8(prefix + "a".repeat(fill) + suffix)
}

///|
/// The kind `f` is refused with, or `None` when it returns.
fn kind_of(f : () -> Unit raise) -> @h1.ParseKind? raise {
  try f() catch {
    @h1.ParseError(kind~, ..) => Some(kind)
    error => raise error
  } noraise {
    _ => None
  }
}

///|
test "head limit accepts 16 KiB and refuses one byte more" {
  let limit = @h1.Limits::default().max_head_bytes
  assert_eq(limit, 16384)
  let request = "GET / HTTP/1.1\r\nHost: h\r\nX: "
  let response = "HTTP/1.1 200 OK\r\nX: "
  for total in [limit, limit + 1] {
    let expected = if total == limit { None } else { Some(@h1.HeadTooLarge) }
    let wire = padded(request, total, "\r\n\r\n")
    assert_eq(wire.length(), total)
    assert_eq(kind_of(() => ignore(@h1.parse_request_head(wire))), expected)
    assert_eq(
      kind_of(() => {
        ignore(@h1.parse_response_head(padded(response, total, "\r\n\r\n")))
      }),
      expected,
    )
    assert_eq(kind_of(() => ignore(@h1.scan_head(wire, max=limit))), expected)
    let whole = @h1.HeadDecoder::new()
    assert_eq(kind_of(() => ignore(whole.feed(wire))), expected)
    let bytewise = @h1.HeadDecoder::new()
    assert_eq(
      kind_of(() => {
        for byte in wire {
          ignore(bytewise.feed([byte]))
        }
      }),
      expected,
    )
  }
  // The same boundary at every split, with a smaller limit.
  let limits = { ..@h1.Limits::default(), max_head_bytes: 64, }
  let at_limit = padded(request, 64, "\r\n\r\n")
  assert_eq(request_refusal(at_limit, limits~), None)
  let past_limit = padded(request, 65, "\r\n\r\n")
  assert_eq(request_refusal(past_limit, limits~), Some(HeadTooLarge))
}

///|
test "empty lines before a request line count against the head limit" {
  let limit = @h1.Limits::default().max_head_bytes
  let request = "GET / HTTP/1.1\r\nHost: h\r\n\r\n"
  for total in [limit, limit + 1] {
    let expected = if total == limit { None } else { Some(@h1.HeadTooLarge) }
    let crlfs = (total - request.length()) / 2
    let padding = if (total - request.length()) % 2 == 0 { "" } else { "a" }
    let wire = @mttp.encode_utf8(
      "\r\n".repeat(crlfs) + "GET /\{padding} HTTP/1.1\r\nHost: h\r\n\r\n",
    )
    assert_eq(wire.length(), total)
    assert_eq(kind_of(() => ignore(@h1.parse_request_head(wire))), expected)
    let decoder = @h1.HeadDecoder::new(skip_leading_crlf=true)
    assert_eq(kind_of(() => ignore(decoder.feed(wire))), expected)
  }
  // Empty lines alone, never followed by a request line, stop at the limit.
  let decoder = @h1.HeadDecoder::new(skip_leading_crlf=true)
  let flood = @mttp.encode_utf8("\r\n".repeat(limit / 2))
  assert_eq(decoder.feed(flood).consumed, limit)
  assert_eq(
    kind_of(() => ignore(decoder.feed(b"\r\n"))),
    Some(@h1.HeadTooLarge),
  )
  // The same boundary at every split, with a smaller limit.
  let limits = { ..@h1.Limits::default(), max_head_bytes: 64, }
  let request = "GET /a HTTP/1.1\r\nHost: h\r\n\r\n"
  let at_limit = @mttp.encode_utf8("\r\n".repeat(18) + request)
  assert_eq(at_limit.length(), 64)
  assert_eq(request_refusal(at_limit, limits~), None)
  let past_limit = @mttp.encode_utf8(
    "\r\n".repeat(18) + "GET /ab HTTP/1.1\r\nHost: h\r\n\r\n",
  )
  assert_eq(request_refusal(past_limit, limits~), Some(@h1.HeadTooLarge))
}

///|
test "head field limit accepts 100 fields and refuses 101" {
  assert_eq(@h1.Limits::default().max_headers, 100)
  for count in [100, 101] {
    let head = StringBuilder()
    head.write_string("GET / HTTP/1.1\r\nHost: h\r\n")
    for i in 1..<count {
      head.write_string("X-\{i}: v\r\n")
    }
    head.write_string("\r\n")
    let wire = @mttp.encode_utf8(head.to_string())
    let expected = if count == 100 { None } else { Some(@h1.HeadTooLarge) }
    assert_eq(kind_of(() => ignore(@h1.parse_request_head(wire))), expected)
  }
}

///|
test "chunk size line limit accepts 4 KiB and refuses one byte more" {
  let limit = @h1.Limits::default().max_chunk_line_bytes
  assert_eq(limit, 4096)
  for total in [limit, limit + 1] {
    let expected = if total == limit { None } else { Some(@h1.HeadTooLarge) }
    // An extension and a run of leading zeros each make a long size line.
    let zeros = @mttp.encode_utf8("0".repeat(total - 3) + "1\r\n")
    for line in [padded("1;", total, "\r\n"), zeros] {
      assert_eq(line.length(), total)
      let decoder = @h1.ChunkedDecoder::new(@h1.Limits::default())
      assert_eq(kind_of(() => ignore(decoder.feed(line))), expected)
    }
  }
  let limits = { ..@h1.Limits::default(), max_chunk_line_bytes: 16, }
  let head = "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n"
  let body = "1;" + "x".repeat(12) + "\r\na\r\n0\r\n\r\n"
  assert_eq(request_refusal(@mttp.encode_utf8(head + body), limits~), None)
  let body = "1;" + "x".repeat(13) + "\r\na\r\n0\r\n\r\n"
  assert_eq(
    request_refusal(@mttp.encode_utf8(head + body), limits~),
    Some(HeadTooLarge),
  )
}

///|
test "trailer section limit accepts 16 KiB and refuses one byte more" {
  let limit = @h1.Limits::default().max_trailer_bytes
  assert_eq(limit, 16384)
  for total in [limit, limit + 1] {
    let expected = if total == limit { None } else { Some(@h1.HeadTooLarge) }
    // The section counts every trailer line and the final CRLF.
    let trailers = padded("X: ", total, "\r\n\r\n")
    let decoder = @h1.ChunkedDecoder::new(@h1.Limits::default())
    assert_eq(
      kind_of(() => {
        ignore(decoder.feed(b"0\r\n"))
        ignore(decoder.feed(trailers))
        decoder.finish()
      }),
      expected,
    )
  }
  let limits = { ..@h1.Limits::default(), max_trailer_bytes: 32, }
  let head = "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n"
  for total in [32, 33] {
    let wire = padded(head + "X: ", head.length() + total, "\r\n\r\n")
    let expected = if total == 32 { None } else { Some(@h1.HeadTooLarge) }
    assert_eq(request_refusal(wire, limits~), expected)
  }
}

///|
test "trailer field limit accepts 100 fields and refuses 101" {
  for count in [100, 101] {
    let trailers = StringBuilder()
    trailers.write_string("0\r\n")
    for i in 0..<count {
      trailers.write_string("X-\{i}: v\r\n")
    }
    trailers.write_string("\r\n")
    let decoder = @h1.ChunkedDecoder::new(@h1.Limits::default())
    let expected = if count == 100 { None } else { Some(@h1.HeadTooLarge) }
    assert_eq(
      kind_of(() => {
        let result = decoder.feed(@mttp.encode_utf8(trailers.to_string()))
        assert_eq(result.trailers.length(), count)
        decoder.finish()
      }),
      expected,
    )
  }
}

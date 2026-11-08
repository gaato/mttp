// Conformance corpus for the codec (RFC 9112). Every case is read through
// `read_request` or `read_response` whole, split in two at every offset and
// byte by byte, and must give the same outcome each way. The cases are data,
// so a new vector is one row.

///|
/// Requests whose framing is ambiguous between implementations: each one is
/// refused as `Smuggling`, never served.
let smuggling_requests : Array[(String, Bytes)] = [
  (
    "CL then TE", b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "TE then CL", b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n0\r\n\r\n",
  ),
  (
    "CL 0 with TE", b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
  ),
  (
    "CL with an unknown coding", b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nTransfer-Encoding: xchunked\r\n\r\nabc",
  ),
  (
    "CL with an uppercase coding", b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nTransfer-Encoding: CHUNKED\r\n\r\nabc",
  ),
  (
    "CL with a padded coding", b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nTransfer-Encoding:  \tchunked \r\n\r\nabc",
  ),
  (
    "CL with an empty TE", b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nTransfer-Encoding:\r\n\r\nabc",
  ),
  (
    "CL with two TE fields", b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\nabc",
  ),
  (
    "CL with a mixed-case TE name", b"POST / HTTP/1.1\r\nHost: h\r\ncOnTeNt-LeNgTh: 3\r\ntRaNsFeR-eNcOdInG: chunked\r\n\r\nabc",
  ),
  (
    "duplicate CL with TE", b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\nabc",
  ),
  (
    "HTTP/1.0 with TE", b"POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "HTTP/1.0 with TE and CL", b"POST / HTTP/1.0\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "Content-Length in trailers", b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\nContent-Length: 10\r\n\r\n",
  ),
  (
    "Transfer-Encoding in trailers", b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nTransfer-Encoding: chunked\r\n\r\n",
  ),
  (
    "Host in trailers", b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nHost: evil\r\n\r\n",
  ),
  (
    "Connection in trailers", b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nConnection: close\r\n\r\n",
  ),
  (
    "Trailer in trailers", b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nTRAILER: x\r\n\r\n",
  ),
]

///|
/// Responses with ambiguous framing, refused as `Smuggling` by a client.
let smuggling_responses : Array[(String, Bytes)] = [
  (
    "CL with TE", b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "CL with TE on a 204, which has no body", b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
  ),
  (
    "HTTP/1.0 with TE", b"HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "Content-Length in trailers", b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 1\r\n\r\n",
  ),
]

///|
/// Requests that disguise framing fields or break RFC 9112 syntax, with the
/// kind each one is refused with. The disguises fail before framing is
/// resolved, so they never reach `request_framing`.
let refused_requests : Array[(String, @h1.ParseKind, Bytes)] = [
  // Disguised field names and line structure.
  (
    "space before the colon",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding : chunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "tab before the colon",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length\t: 3\r\n\r\nabc",
  ),
  (
    "obs-fold continuing TE",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip,\r\n chunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "obs-fold with a tab",
    Malformed,
    b"GET / HTTP/1.1\r\nHost: h\r\nX: a\r\n\tb\r\n\r\n",
  ),
  (
    "whitespace before the first field",
    Malformed,
    b"GET / HTTP/1.1\r\n Host: h\r\n\r\n",
  ),
  (
    "bare LF ending a field",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\n\r\n0\r\n\r\n",
  ),
  ("bare LF everywhere", Malformed, b"GET / HTTP/1.1\nHost: h\n\n"),
  (
    "bare CR inside a field",
    Malformed,
    b"GET / HTTP/1.1\r\nHost: h\rX: y\r\n\r\n",
  ),
  (
    "NUL in TE",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\x00\r\n\r\n0\r\n\r\n",
  ),
  (
    "vertical tab before TE",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:\x0bchunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "field without a colon",
    Malformed,
    b"GET / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding chunked\r\n\r\n",
  ),
  ("empty field name", Malformed, b"GET / HTTP/1.1\r\nHost: h\r\n: x\r\n\r\n"),
  (
    "DEL in a field value",
    Malformed,
    b"GET / HTTP/1.1\r\nHost: h\r\nX: a\x7fb\r\n\r\n",
  ),
  // Content-Length.
  (
    "identical duplicate CL",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nContent-Length: 3\r\n\r\nabc",
  ),
  (
    "conflicting CL",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabcd",
  ),
  (
    "CL list",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 3, 3\r\n\r\nabc",
  ),
  (
    "signed CL",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: +3\r\n\r\nabc",
  ),
  (
    "negative CL",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: -1\r\n\r\n",
  ),
  (
    "hexadecimal CL",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 0x3\r\n\r\nabc",
  ),
  (
    "CL with inner space",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 1 2\r\n\r\nabc",
  ),
  (
    "empty CL",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length:\r\n\r\n",
  ),
  (
    "CL past Int64",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 9223372036854775808\r\n\r\n",
  ),
  // Transfer-Encoding without Content-Length.
  (
    "chunked twice in one field",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked, chunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "chunked in two fields",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "empty element after chunked",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked,\r\n\r\n0\r\n\r\n",
  ),
  (
    "empty element before chunked",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: , chunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "empty TE",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding:\r\n\r\n",
  ),
  (
    "gzip",
    Unsupported,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip\r\n\r\nabc",
  ),
  (
    "gzip then chunked",
    Unsupported,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n",
  ),
  (
    "chunked not last",
    Unsupported,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked, gzip\r\n\r\n0\r\n\r\n",
  ),
  (
    "identity",
    Unsupported,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: identity\r\n\r\nabc",
  ),
  (
    "chunked with a parameter",
    Unsupported,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked;q=1\r\n\r\n0\r\n\r\n",
  ),
  (
    "obfuscated chunked",
    Unsupported,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\x80\r\n\r\n0\r\n\r\n",
  ),
  // Chunked bodies.
  (
    "size past Int64",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n8000000000000000\r\n",
  ),
  (
    "size past 64 bits",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n10000000000000000\r\n",
  ),
  (
    "negative size",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n-1\r\n",
  ),
  (
    "hexadecimal prefix",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0x1\r\na\r\n0\r\n\r\n",
  ),
  (
    "space before the size",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n 1\r\na\r\n0\r\n\r\n",
  ),
  (
    "space after the size",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n1 \r\na\r\n0\r\n\r\n",
  ),
  (
    "bare LF after the size",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n1\na\r\n0\r\n\r\n",
  ),
  (
    "bare LF inside an extension",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n1;x\na\r\n0\r\n\r\n",
  ),
  (
    "quoted LF inside an extension",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n1;x=\"\n\"\r\na\r\n0\r\n\r\n",
  ),
  (
    "data longer than the size",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nab\r\n0\r\n\r\n",
  ),
  (
    "data without CRLF",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na0\r\n\r\n",
  ),
  (
    "LF only after data",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\n0\r\n\r\n",
  ),
  (
    "truncated body",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nab",
  ),
  (
    "last chunk without the trailer CRLF",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n",
  ),
  (
    "obs-fold in trailers",
    Malformed,
    b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX: a\r\n b\r\n\r\n",
  ),
  // Request lines.
  // Empty lines before the request line are skipped only as CRLF.
  ("leading bare LF", Malformed, b"\nGET / HTTP/1.1\r\nHost: h\r\n\r\n"),
  (
    "bare LF after a leading CRLF",
    Malformed,
    b"\r\n\nGET / HTTP/1.1\r\nHost: h\r\n\r\n",
  ),
  ("leading bare CR", Malformed, b"\rGET / HTTP/1.1\r\nHost: h\r\n\r\n"),
  ("only empty lines", Malformed, b"\r\n\r\n\r\n"),
  ("two spaces", Malformed, b"GET  / HTTP/1.1\r\nHost: h\r\n\r\n"),
  ("tab separator", Malformed, b"GET\t/ HTTP/1.1\r\nHost: h\r\n\r\n"),
  ("trailing space", Malformed, b"GET / HTTP/1.1 \r\nHost: h\r\n\r\n"),
  ("lowercase version", Malformed, b"GET / http/1.1\r\nHost: h\r\n\r\n"),
  ("version without minor", Malformed, b"GET / HTTP/1\r\nHost: h\r\n\r\n"),
  ("two-digit minor", Malformed, b"GET / HTTP/1.10\r\nHost: h\r\n\r\n"),
  ("HTTP/2", Unsupported, b"GET / HTTP/2.0\r\nHost: h\r\n\r\n"),
  ("HTTP/0.9", Unsupported, b"GET / HTTP/0.9\r\nHost: h\r\n\r\n"),
  ("missing Host", Malformed, b"GET / HTTP/1.1\r\n\r\n"),
  ("two Hosts", Malformed, b"GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"),
  ("Host list", Malformed, b"GET / HTTP/1.1\r\nHost: a, b\r\n\r\n"),
  ("Host with userinfo", Malformed, b"GET / HTTP/1.1\r\nHost: u@h\r\n\r\n"),
  ("fragment", Malformed, b"GET /#x HTTP/1.1\r\nHost: h\r\n\r\n"),
  ("non-ASCII target", Malformed, b"GET /\xff HTTP/1.1\r\nHost: h\r\n\r\n"),
]

///|
/// Responses with RFC 9112 syntax errors and the kind each is refused with.
let refused_responses : Array[(String, @h1.ParseKind, Bytes)] = [
  ("two-digit status", Malformed, b"HTTP/1.1 20 OK\r\n\r\n"),
  ("four-digit status", Malformed, b"HTTP/1.1 2000\r\n\r\n"),
  ("status below 100", Malformed, b"HTTP/1.1 099 Low\r\n\r\n"),
  ("status above 599", Malformed, b"HTTP/1.1 600 High\r\n\r\n"),
  ("letter in status", Malformed, b"HTTP/1.1 2x0 OK\r\n\r\n"),
  ("no space before the reason", Malformed, b"HTTP/1.1 200OK\r\n\r\n"),
  ("two spaces before the status", Malformed, b"HTTP/1.1  200 OK\r\n\r\n"),
  ("NUL in the reason", Malformed, b"HTTP/1.1 200 O\x00K\r\n\r\n"),
  ("lowercase version", Malformed, b"http/1.1 200 OK\r\n\r\n"),
  ("HTTP/2", Unsupported, b"HTTP/2.0 200 OK\r\n\r\n"),
  (
    "duplicate CL",
    Malformed,
    b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\na",
  ),
  (
    "gzip transfer coding",
    Unsupported,
    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\nabc",
  ),
  (
    "truncated chunked body",
    Malformed,
    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nab",
  ),
  ("truncated head", Malformed, b"HTTP/1.1 200 OK\r\nX: y\r\n"),
  // Only a server skips empty lines before the start line.
  ("leading empty line", Malformed, b"\r\nHTTP/1.1 200 OK\r\n\r\n"),
]

///|
test "smuggling corpus is refused as Smuggling at every split" {
  for case in smuggling_requests {
    let (name, wire) = case
    assert_eq(request_refusal(wire), Some(Smuggling), msg="request: \{name}")
  }
  for case in smuggling_responses {
    let (name, wire) = case
    assert_eq(response_refusal(wire), Some(Smuggling), msg="response: \{name}")
  }
}

///|
test "malformed and unsupported corpus is refused with its kind at every split" {
  for case in refused_requests {
    let (name, kind, wire) = case
    assert_eq(request_refusal(wire), Some(kind), msg="request: \{name}")
  }
  for case in refused_responses {
    let (name, kind, wire) = case
    assert_eq(response_refusal(wire), Some(kind), msg="response: \{name}")
  }
}

///|
test "accepted requests read identically at every split" {
  // (name, wire, framing, body, rest)
  let cases : Array[(String, Bytes, @h1.Framing, Bytes, Bytes)] = [
    ("no body", b"GET / HTTP/1.1\r\nHost: h\r\n\r\n", NoBody, b"", b""),
    (
      "length with a pipelined request",
      b"POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nabcGET / HTTP/1.1\r\n",
      Length(3),
      b"abc",
      b"GET / HTTP/1.1\r\n",
    ),
    (
      "length with leading zeros and OWS",
      b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: \t007 \r\n\r\n1234567",
      Length(7),
      b"1234567",
      b"",
    ),
    (
      "zero length",
      b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\nX",
      Length(0),
      b"",
      b"X",
    ),
    (
      "chunked with extensions, uppercase hex and trailers",
      b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: Chunked\r\n\r\n000A;a=b;c=\"d;\\\"e\"\r\n0123456789\r\n2 ; x\r\nab\r\n0\r\nX-Sum: 1\r\n\r\nNEXT",
      Chunked,
      b"0123456789ab",
      b"NEXT",
    ),
    (
      "chunked padded with OWS",
      b"POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: \tchunked \r\n\r\n0\r\n\r\n",
      Chunked,
      b"",
      b"",
    ),
    (
      "an underscore name is not Transfer-Encoding",
      b"POST / HTTP/1.1\r\nHost: h\r\nTransfer_Encoding: chunked\r\n\r\n0\r\n\r\n",
      NoBody,
      b"",
      b"0\r\n\r\n",
    ),
    (
      "HTTP/1.0 without Host",
      b"POST / HTTP/1.0\r\nContent-Length: 2\r\n\r\nhi",
      Length(2),
      b"hi",
      b"",
    ),
    (
      "a higher HTTP/1 minor version",
      b"GET / HTTP/1.2\r\nHost: h\r\n\r\n",
      NoBody,
      b"",
      b"",
    ),
    (
      "one leading empty line",
      b"\r\nGET / HTTP/1.1\r\nHost: h\r\n\r\n",
      NoBody,
      b"",
      b"",
    ),
    (
      "several leading empty lines before a body",
      b"\r\n\r\n\r\nPOST / HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\nhi",
      Length(2),
      b"hi",
      b"",
    ),
    (
      "obs-text and empty values",
      b"GET / HTTP/1.1\r\nHost: h\r\nX: \xe9t\xe9\r\nY:\r\n\r\n",
      NoBody,
      b"",
      b"",
    ),
  ]
  for case in cases {
    let (name, wire, framing, body, rest) = case
    let message = check_splits(wire, pieces => read_request(pieces))
    guard message is Ok(message) else { fail("refused: \{name}") }
    assert_eq(message.framing, framing, msg=name)
    assert_eq(message.body, body, msg=name)
    assert_eq(message.rest, rest, msg=name)
    // Skipped empty lines are not part of the returned head.
    assert_true(message.head is [b'A'..<=b'Z', ..], msg=name)
  }
  // A client's extra CRLF after a body on a kept-alive connection: the next
  // request is read from the bytes after the first.
  let wire = b"POST / HTTP/1.1\r\nHost: h\r\nContent-Length: 2\r\n\r\nhi\r\nGET /next HTTP/1.1\r\nHost: h\r\n\r\n"
  guard read_request([wire]) is Ok(first) else { fail("first refused") }
  assert_eq(first.rest, b"\r\nGET /next HTTP/1.1\r\nHost: h\r\n\r\n")
  guard check_splits(first.rest, pieces => read_request(pieces)) is Ok(next) else {
    fail("next refused")
  }
  assert_eq(@h1.parse_request_head(next.head).target, "/next")
  assert_eq(
    @h1.parse_request_head(b"\r\n\r\nGET /x HTTP/1.1\r\nHost: h\r\n\r\n").target,
    "/x",
  )
  let request = @h1.parse_request_head(b"GET / HTTP/1.2\r\nHost: h\r\n\r\n")
  assert_eq(request.version, Http11)
  let request = @h1.parse_request_head(
    b"GET / HTTP/1.1\r\nHost: h\r\nX: \xe9t\xe9\r\nY:\r\n\r\n",
  )
  assert_eq(request.headers.get("x"), Some("\u{e9}t\u{e9}"))
  assert_eq(request.headers.get("y"), Some(""))
}

///|
test "accepted responses read identically at every split" {
  // (name, request method, wire, framing, body, rest)
  let cases : Array[(String, @http.Method, Bytes, @h1.Framing, Bytes, Bytes)] = [
    (
      "no reason phrase",
      Get,
      b"HTTP/1.1 200\r\nContent-Length: 2\r\n\r\nok",
      Length(2),
      b"ok",
      b"",
    ),
    (
      "empty reason phrase",
      Get,
      b"HTTP/1.1 200 \r\nContent-Length: 2\r\n\r\nok",
      Length(2),
      b"ok",
      b"",
    ),
    (
      "reason with spaces, tabs and obs-text",
      Get,
      b"HTTP/1.1 404 Not \tF\xf6und \r\nContent-Length: 0\r\n\r\n",
      Length(0),
      b"",
      b"",
    ),
    (
      "close-delimited",
      Get,
      b"HTTP/1.1 200 OK\r\n\r\neverything until close",
      UntilClose,
      b"everything until close",
      b"",
    ),
    (
      "HTTP/1.0 close-delimited",
      Get,
      b"HTTP/1.0 200 OK\r\n\r\nold",
      UntilClose,
      b"old",
      b"",
    ),
    (
      "chunked with trailers",
      Get,
      b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n0\r\nX-A: 1\r\nX-A: 2\r\n\r\n",
      Chunked,
      b"Wiki",
      b"",
    ),
    (
      "HEAD with a length",
      Head,
      b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nHTTP/1.1 204\r\n\r\n",
      NoBody,
      b"",
      b"HTTP/1.1 204\r\n\r\n",
    ),
    (
      "304 with a length",
      Get,
      b"HTTP/1.1 304 Not Modified\r\nContent-Length: 10\r\n\r\n",
      NoBody,
      b"",
      b"",
    ),
    (
      "CONNECT tunnel bytes",
      Connect,
      b"HTTP/1.1 200 Connection Established\r\n\r\n\x16\x03\x01",
      NoBody,
      b"",
      b"\x16\x03\x01",
    ),
    (
      "informational",
      Get,
      b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\n",
      NoBody,
      b"",
      b"HTTP/1.1 200 OK\r\n",
    ),
  ]
  for case in cases {
    let (name, meth, wire, framing, body, rest) = case
    let message = check_splits(wire, pieces => read_response(pieces, meth~))
    guard message is Ok(message) else { fail("refused: \{name}") }
    assert_eq(message.framing, framing, msg=name)
    assert_eq(message.body, body, msg=name)
    assert_eq(message.rest, rest, msg=name)
  }
  let response = @h1.parse_response_head(
    b"HTTP/1.1 503\r\nRetry-After: 1\r\n\r\n",
  )
  assert_eq(response.status, 503)
  assert_eq(response.headers.get("retry-after"), Some("1"))
  let chunked = check_splits(
    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-A: 1\r\nX-A: 2\r\n\r\n",
    pieces => read_response(pieces),
  )
  guard chunked is Ok(chunked) else { fail("refused trailers") }
  assert_eq(chunked.trailers.get_all("x-a"), ["1", "2"])
}

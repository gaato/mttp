// Request smuggling end to end: every head whose body framing two parsers
// could read differently is refused with one 400 (or 501 for a coding the
// engine does not implement) and the connection closes, so the bytes after
// it are never read as a second request.

///|
/// Heads with ambiguous or refused framing, each followed by a body that
/// hides a second request.
let smuggling_corpus : Array[(String, String)] = [
  ("Content-Length: 4\r\nTransfer-Encoding: chunked\r\n", "400"),
  ("Transfer-Encoding: chunked\r\nContent-Length: 4\r\n", "400"),
  ("Content-Length: 0\r\nTransfer-Encoding: chunked\r\n", "400"),
  ("Content-Length: 4\r\nTransfer-Encoding: xchunked\r\n", "400"),
  ("Content-Length: 4\r\nTransfer-Encoding: CHUNKED\r\n", "400"),
  ("Content-Length: 4\r\nTransfer-Encoding:  \tchunked \r\n", "400"),
  ("Content-Length: 4\r\nTransfer-Encoding:\r\n", "400"),
  (
    "Transfer-Encoding: gzip\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n",
    "400",
  ),
  ("cOnTeNt-LeNgTh: 4\r\ntRaNsFeR-eNcOdInG: chunked\r\n", "400"),
  (
    "Content-Length: 4\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n", "400",
  ),
  ("Content-Length: 4\r\nContent-Length: 4\r\n", "400"),
  ("Content-Length: 4\r\nContent-Length: 5\r\n", "400"),
  ("Content-Length: 4, 4\r\n", "400"),
  ("Content-Length: +4\r\n", "400"),
  ("Content-Length: 0x4\r\n", "400"),
  ("Content-Length: 4 \r\nContent-Length: 5\r\n", "400"),
  ("Transfer-Encoding : chunked\r\n", "400"),
  ("Transfer-Encoding:\tchunked\r\nX: y\r\n z\r\n", "400"),
  (" Transfer-Encoding: chunked\r\n", "400"),
  ("Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n", "400"),
  ("Transfer-Encoding: chunked, chunked\r\n", "400"),
  ("Transfer-Encoding: gzip, chunked\r\n", "501"),
  ("Transfer-Encoding: chunked, identity\r\n", "501"),
  ("Transfer-Encoding: xchunked\r\n", "501"),
]

///|
test "ambiguous framing is refused once and nothing after it is served" {
  for chunk_bytes in [1, 17, 65536] {
    for case in smuggling_corpus {
      let (fields, status) = case
      let h = Harness::new()
      let calls = Ref(0)
      let wire = "POST / HTTP/1.1\r\nHost: example.test\r\n\{fields}\r\n0\r\n\r\n" +
        get("/smuggled")
      let out = h.exchange(
        @mttp.encode_utf8(wire),
        _ => {
          calls.val += 1
          @mttp.Response::new(200)
        },
        chunk_bytes~,
      )
      assert_true(
        out.has_prefix("HTTP/1.1 \{status} "),
        msg="\{fields} -> \{out}",
      )
      assert_eq(out.split("HTTP/1.1 ").count(), 2, msg=fields)
      assert_true(out.contains("connection: close\r\n"))
      assert_eq(calls.val, 0, msg=fields)
    }
  }
}

///|
test "the smuggling corpus forbidden trailers never expose a second request" {
  for
    field in [
      "Content-Length", "Transfer-Encoding", "Host", "Connection", "TRAILER",
    ] {
    for chunk_bytes in [1, 17, 65536] {
      let h = Harness::new()
      let calls = Ref(0)
      let wire = "POST / HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\n\{field}: x\r\n\r\n" +
        get("/smuggled")
      let out = h.exchange(
        @mttp.encode_utf8(wire),
        request => {
          calls.val += 1
          echo()(request)
        },
        chunk_bytes~,
      )
      assert_true(out.has_prefix("HTTP/1.1 400 "), msg=field)
      assert_eq(out.split("HTTP/1.1 ").count(), 2, msg=field)
      assert_eq(calls.val, 1)
      assert_eq(h.errors.map(kind_phase), [(Protocol, Body)])
    }
  }
}

///|
test "Transfer-Encoding on HTTP/1.0 is refused even with a valid length" {
  for length in ["", "Content-Length: 5\r\n"] {
    let h = Harness::new()
    let calls = Ref(0)
    let out = h.exchange(
      @mttp.encode_utf8(
        "POST / HTTP/1.0\r\n\{length}Transfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /smuggled HTTP/1.0\r\n\r\n",
      ),
      _ => {
        calls.val += 1
        @mttp.Response::new(200)
      },
    )
    assert_true(out.has_prefix("HTTP/1.1 400 "))
    assert_eq(out.split("HTTP/1.1 ").count(), 2)
    assert_eq(calls.val, 0)
  }
}

///|
test "a body framed by its length never leaks into the next request" {
  // The body spells a request; it is read as body bytes and never served.
  let hidden = get("/hidden")
  let h = Harness::new()
  let urls = []
  let out = h.exchange(@mttp.encode_utf8(post("/", hidden) + get("/next")), request => {
    urls.push(request.url)
    let body = body_of(request) catch { _ => b"" }
    @mttp.Response::new(200, body=Bytes(body))
  })
  assert_eq(urls, ["http://example.test/", "http://example.test/next"])
  assert_eq(out.split("HTTP/1.1 200").count(), 3)
}

///|
test "bad chunk framing is refused and the connection closes" {
  for
    body in [
      "invalid\r\n", "4\r\nabcde\r\n0\r\n\r\n", "4\nabcd\n0\n\n", "-1\r\n", "4 \r\nabcd\r\n0\r\n\r\n",
      "fffffffffffffffff\r\n",
    ] {
    let h = Harness::new()
    let out = h.exchange(
      @mttp.encode_utf8(
        "POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\n\r\n" +
        body +
        get("/smuggled"),
      ),
      echo(),
    )
    assert_true(out.has_prefix("HTTP/1.1 400 "), msg="\{body} -> \{out}")
    assert_eq(out.split("HTTP/1.1 ").count(), 2)
    assert_eq(h.errors.map(kind_phase), [(Protocol, Body)])
  }
}

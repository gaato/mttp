// Trailer fields over HTTP/1.1 (RFC 9112, section 7.1.2): the last chunk's
// trailer section, received after a chunked request body and sent after a
// chunked response body.

///|
test "a chunked request's trailers reach the handler once it read the body" {
  let h = Harness::new()
  let handler : @mttp_core.Handler = request => {
    let before = request.body.trailers().length()
    let body = request.body.read_all(max=1024) catch { _ => b"" }
    let sum = request.body.trailers().get("x-checksum").unwrap_or("none")
    @mttp_core.Response::new(
      200,
      body=Bytes(@utf8.encode("\{before} \{@utf8.decode_lossy(body)} \{sum}")),
    )
  }
  let out = h.exchange(
    b"POST / HTTP/1.1\r\nHost: example.test\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\nabc\r\n0\r\nX-Checksum: 9\r\n\r\n",
    handler,
  )
  assert_true(out.has_prefix("HTTP/1.1 200 "), msg=out)
  assert_true(out.has_suffix("\r\n\r\n0 abc 9"), msg=out)
}

///|
test "a response body's trailers go in its last chunk" {
  let h = Harness::new()
  let handler : @mttp_core.Handler = _ => {
    ..@mttp_core.Response::new(200),
    body: @mttp_core.Body::with_trailers(
      b"abc",
      trailers=@mttp_core.Headers::of([("grpc-status", "0")]),
    ),
  }
  let out = h.exchange(
    b"GET / HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n", handler,
  )
  assert_true(out.contains("transfer-encoding: chunked\r\n"), msg=out)
  assert_true(
    out.has_suffix("3\r\nabc\r\n0\r\ngrpc-status: 0\r\n\r\n"),
    msg=out,
  )
}

///|
/// A trailer that names a framing field cannot be sent; the response does
/// not end as whole (no last chunk), as when its producer fails.
test "a response body's framing trailer cuts the response short" {
  let h = Harness::new()
  let handler : @mttp_core.Handler = _ => {
    ..@mttp_core.Response::new(200),
    body: @mttp_core.Body::with_trailers(
      b"abc",
      trailers=@mttp_core.Headers::of([("transfer-encoding", "gzip")]),
    ),
  }
  let out = h.exchange(
    b"GET / HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n", handler,
  )
  assert_true(out.has_suffix("3\r\nabc\r\n"), msg=out)
  assert_eq(h.errors.length(), 1)
}

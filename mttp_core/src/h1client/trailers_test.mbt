// Trailer fields over HTTP/1.1 (RFC 9112, section 7.1.2): the last chunk's
// trailer section, received after a chunked response body and sent after a
// chunked request body.

///|
test "a chunked response's trailers are the body's once it is read" {
  let h = Harness::new()
  ignore(
    h.scripted([
      Chunk(
        b"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\nx-checksum: 9\r\ngrpc-status: 0\r\n\r\n",
      ),
    ]),
  )
  h.run(() => {
    let response = h.client.send(
      @mttp_core.Request::get("http://example.test/"),
      streaming(),
    )
    // Before the end there are none to see.
    assert_eq(response.body.trailers().length(), 0)
    assert_eq(response.body.read_all(max=1024), b"abc")
    assert_eq(response.body.trailers().get("x-checksum"), Some("9"))
    assert_eq(response.body.trailers().get("grpc-status"), Some("0"))
    // The trailers are not merged into the head.
    assert_eq(response.headers.get("x-checksum"), None)
    h.finish()
  })
}

///|
test "a request body's trailers go in its last chunk" {
  let h = Harness::new()
  let conn = h.scripted([Chunk(b"HTTP/1.1 204 No Content\r\n\r\n")])
  h.run(() => {
    let request = {
      ..@mttp_core.Request::post("http://example.test/"),
      body: @mttp_core.Body::with_trailers(
        b"abc",
        trailers=@mttp_core.Headers::of([("x-checksum", "9")]),
      ),
    }
    h.client.send(request, exchange()).close()
    h.finish()
  })
  let written = conn.written().fold(init=b"", (a, b) => a + b)
  let text = @utf8.decode(written)
  assert_true(text.contains("transfer-encoding: chunked\r\n"), msg=text)
  assert_true(
    text.has_suffix("3\r\nabc\r\n0\r\nx-checksum: 9\r\n\r\n"),
    msg=text,
  )
}

///|
/// A trailer that names a framing field would be refused by the recipient
/// as smuggling; the sender fails the upload instead of ending the request
/// as whole.
test "a request body's framing trailer fails the upload" {
  let h = Harness::new()
  let conn = h.scripted([Chunk(b"HTTP/1.1 204 No Content\r\n\r\n")])
  h.run(() => {
    let request = {
      ..@mttp_core.Request::post("http://example.test/"),
      body: @mttp_core.Body::with_trailers(
        b"abc",
        trailers=@mttp_core.Headers::of([("content-length", "3")]),
      ),
    }
    let failed = try h.client.send(request, exchange()) catch {
      @mttp_core.TransportError(kind~, phase~, ..) => Some((kind, phase))
    } noraise {
      response => {
        response.close()
        None
      }
    }
    assert_eq(failed, Some((Invalid, Body)))
    h.finish()
  })
  let written = conn.written().fold(init=b"", (a, b) => a + b)
  assert_false(@utf8.decode(written).contains("0\r\n"))
}

///|
/// An empty body may still have trailers: the head and the last chunk with
/// them, or, when they cannot be sent, nothing that ends the request.
test "an empty body's trailers go in its last chunk, or fail the upload" {
  let h = Harness::new()
  let conn = h.scripted([Chunk(b"HTTP/1.1 204 No Content\r\n\r\n")])
  h.run(() => {
    let request = {
      ..@mttp_core.Request::post("http://example.test/"),
      body: @mttp_core.Body::with_trailers(
        b"",
        trailers=@mttp_core.Headers::of([("x-checksum", "0")]),
      ),
    }
    h.client.send(request, exchange()).close()
    h.finish()
  })
  let text = @utf8.decode(conn.written().fold(init=b"", (a, b) => a + b))
  assert_true(text.has_suffix("\r\n\r\n0\r\nx-checksum: 0\r\n\r\n"), msg=text)
  let h = Harness::new()
  ignore(h.scripted([Chunk(b"HTTP/1.1 204 No Content\r\n\r\n")]))
  h.run(() => {
    let request = {
      ..@mttp_core.Request::post("http://example.test/"),
      body: @mttp_core.Body::with_trailers(
        b"",
        trailers=@mttp_core.Headers::of([("host", "x")]),
      ),
    }
    let failed = try h.client.send(request, exchange()) catch {
      @mttp_core.TransportError(kind~, ..) => Some(kind)
    } noraise {
      response => {
        response.close()
        None
      }
    }
    assert_eq(failed, Some(Invalid))
    h.finish()
  })
}

// Trailer sections over HTTP/2 (RFC 9113, section 8.1): a HEADERS frame
// after the body, both ways, between this module's client and server.

///|
async test "trailers go both ways over HTTP/2" {
  with_server(port => {
    let b = h2_client()
    defer b.close()
    let request = {
      ..@mttp_core.Request::post("https://localhost:\{port}/trailers"),
      body: @mttp_core.Body::with_trailers(
        b"abc",
        trailers=@mttp_core.Headers::of([("x-checksum", "9")]),
      ),
    }
    let response = b.send(request, defaults)
    assert_eq(response.status, 200)
    assert_eq(response.attributes.get(@mttp_core.protocol), Some("h2"))
    assert_eq(text(response), "abc 9")
    assert_eq(response.body.trailers().get("grpc-status"), Some("0"))
    assert_eq(response.headers.get("grpc-status"), None)
  })
}

///|
/// A response whose trailers cannot be sent is reset, not ended as whole.
async test "a response trailer HTTP/2 cannot carry resets the stream" {
  with_server(port => {
    let b = h2_client()
    defer b.close()
    let response = b.send(
      @mttp_core.Request::get("https://localhost:\{port}/trailers?bad"),
      defaults,
    )
    let failed = try response.body.read_all(max=1024) catch {
      @mttp_core.TransportError(phase~, ..) => Some(phase)
    } noraise {
      _ => None
    }
    assert_eq(failed, Some(Body))
  })
}

///|
/// A request whose trailers HTTP/2 cannot carry fails its upload; the
/// stream is reset rather than ended as whole.
async test "a request trailer HTTP/2 cannot carry fails the upload" {
  with_server(port => {
    let b = h2_client()
    defer b.close()
    let request = {
      ..@mttp_core.Request::post("https://localhost:\{port}/trailers"),
      body: @mttp_core.Body::with_trailers(
        b"abc",
        trailers=@mttp_core.Headers::of([("te", "gzip")]),
      ),
    }
    let failed = try b.send(request, defaults) catch {
      @mttp_core.TransportError(kind~, ..) => Some(kind)
    } noraise {
      response => {
        response.close()
        None
      }
    }
    assert_eq(failed, Some(Invalid))
  })
}

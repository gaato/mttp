// The request libcurl sends is the request it was given: the method as it
// is, the body as it is, and no field of libcurl's own besides framing.

///|
/// The fields a sent request may carry besides its own: what libcurl writes
/// from the URL and the body, and HTTP/2's pseudo-fields.
fn framing_field(name : String) -> Bool {
  name.has_prefix(":") ||
  name is ("host" | "content-length" | "transfer-encoding")
}

///|
/// A body of `kind` with `n` bytes: Empty, Bytes or a stream in two pieces.
fn body_of(
  request : @mttp_core.Request,
  kind : String,
  n : Int32,
) -> @mttp_core.Request {
  match kind {
    "bytes" => request.body_bytes(Bytes::make(n, b'b'))
    "stream" => {
      let half = Bytes::make(n / 2, b's')
      request.body_stream(Pieces::{ pieces: [half, half], next: 0, closed: 0, })
    }
    _ => request
  }
}

///|
async test "every method and body is sent as given, over HTTP/2 and HTTP/1.1" {
  with_server(server => {
    let h2 = tls_backend()
    let h1 = CurlBackend::with_version(
      2,
      http3=false,
      trust=PemFile(testdata("root.pem")),
    )
    defer {
      h2.close()
      h1.close()
    }
    let methods : Array[@mttp_core.Method] = [
      Get,
      Post,
      Put,
      Patch,
      Delete,
      Options,
      Other("PURGE"),
    ]
    for pair in [(h2, "h2"), (h1, "http/1.1")] {
      let (backend, protocol) = pair
      for meth in methods {
        for kind in ["empty", "bytes", "stream"] {
          let request = body_of(
            @mttp_core.Request::new(meth, server.tls + "/echo").header(
              "x-probe", "1",
            ),
            kind,
            10,
          )
          let label = "\{protocol} \{meth} \{kind}"
          let response = backend.send(
            request,
            @mttp_core.SendOptions::default(),
          )
          assert_eq(
            response.headers.get("x-method"),
            Some(meth.to_string()),
            msg=label,
          )
          let expected = if kind == "empty" { "0" } else { "10" }
          assert_eq(
            response.headers.get("x-received"),
            Some(expected),
            msg=label,
          )
          guard fields(response) is Object(seen) else { fail("no fields") }
          // The request's own fields (body_stream adds a Content-Type of
          // its own) and framing; anything else is libcurl's.
          let given = request.headers.iter().map(f => f.0.to_lower()).to_array()
          for name, _ in seen {
            if !given.contains(name) && !framing_field(name) {
              fail("\{label}: a field of libcurl's own: \{name}")
            }
          }
          // No body where one is expected still says so.
          if kind == "empty" && meth is (Post | Put | Patch) {
            assert_eq(
              seen.get("content-length"),
              Some(Json::string("0")),
              msg=label,
            )
          }
          text(response) |> ignore
        }
      }
    }
  })
}

///|
async test "HEAD is sent as HEAD, and a HEAD with a body is refused before any I/O" {
  with_server(server => {
    let backend = tls_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::new(Head, server.tls + "/echo"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(response.headers.get("x-method"), Some("HEAD"))
    assert_eq(text(response), "")
    let e = send_error(
      backend,
      @mttp_core.Request::new(Head, server.tls + "/echo").body_bytes(b"x"),
    )
    guard e is @mttp_core.TransportError(kind=Invalid, phase=Pool, ..) else {
      fail("unexpected \{e.to_repr()}")
    }
  })
}

///|
async test "an empty field value and the request target arrive as given" {
  with_server(server => {
    for
      backend in [
        tls_backend(),
        CurlBackend::with_version(
          2,
          http3=false,
          trust=PemFile(testdata("root.pem")),
        ),
      ] {
      defer backend.close()
      let response = backend.send(
        @mttp_core.Request::get(server.tls + "/echo/./a/../b").header(
          "x-empty", "",
        ),
        @mttp_core.SendOptions::default(),
      )
      assert_eq(response.headers.get("x-target"), Some("/echo/./a/../b"))
      guard fields(response) is Object(seen) else { fail("no fields") }
      assert_eq(seen.get("x-empty"), Some(Json::string("")))
      text(response) |> ignore
    }
  })
}

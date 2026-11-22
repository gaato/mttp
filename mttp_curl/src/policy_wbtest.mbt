///|
/// The request fields /echo saw, as JSON.
fn fields(response : @mttp_core.Response) -> Json {
  @json.parse(response.headers.get("x-fields").unwrap_or("{}")) catch {
    _ => Json::null()
  }
}

///|
async test "a 3xx comes back as it is" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.h2c + "/redirect"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(response.status, 302)
    assert_eq(response.headers.get("location"), Some("/hello"))
  })
}

///|
async test "a coded body comes back coded" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.h2c + "/gzip"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(response.headers.get("content-encoding"), Some("gzip"))
    let body = response.body.read_all(max=1000)
    // The gzip magic number, not "hello gzip".
    assert_eq(body[0:2].to_owned(), b"\x1f\x8b")
  })
}

///|
async test "the request carries what it was given and no Expect or Accept of curl's" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::put(server.h2c + "/echo")
      .header("x-custom", "yes")
      .body_bytes(b"0123456789"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(response.headers.get("x-method"), Some("PUT"))
    assert_eq(response.headers.get("x-received"), Some("10"))
    let seen = fields(response)
    guard seen is Object(seen) else { fail("no fields") }
    assert_eq(seen.get("x-custom"), Some(Json::string("yes")))
    assert_eq(seen.get("expect"), None)
    assert_eq(seen.get("accept"), None)
    assert_eq(text(response), "0123456789")
  })
}

///|
async test "an empty POST says Content-Length: 0" {
  with_server(server => {
    let backend = tls_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::post(server.tls + "/echo"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(response.headers.get("x-method"), Some("POST"))
    guard fields(response) is Object(seen) else { fail("no fields") }
    assert_eq(seen.get("content-length"), Some(Json::string("0")))
  })
}

///|
/// A request body in pieces, counting the reads it was asked for.
priv struct Pieces {
  pieces : Array[Bytes]
  mut next : Int32
  mut closed : Int32
}

///|
impl @mttp_core.BodyStream for Pieces with fn read_some(self) {
  guard self.next < self.pieces.length() else { return None }
  self.next += 1
  Some(self.pieces[self.next - 1])
}

///|
impl @mttp_core.BodyStream for Pieces with fn close(self) {
  self.closed += 1
}

///|
async test "a streamed upload is sent piece by piece and closed once" {
  with_server(server => {
    for base in [server.h2c] {
      let backend = h2c_backend()
      defer backend.close()
      let piece = Bytes::make(70000, b'x')
      let source = Pieces::{
        pieces: [piece, piece, piece],
        next: 0,
        closed: 0,
      }
      let response = backend.send(
        @mttp_core.Request::post(base + "/echo").body_stream(source),
        @mttp_core.SendOptions::default(),
      )
      assert_eq(response.headers.get("x-received"), Some("210000"))
      assert_eq(text(response).length(), 210000)
      assert_eq(source.closed, 1)
    }
  })
}

///|
async test "a streamed upload over HTTP/1.1 uses chunked framing" {
  with_server(server => {
    let backend = CurlBackend::with_version(
      2,
      http3=false,
      trust=PemFile(testdata("root.pem")),
    )
    defer backend.close()
    let source = Pieces::{ pieces: [b"abc", b"def"], next: 0, closed: 0, }
    let response = backend.send(
      @mttp_core.Request::post(server.tls + "/echo").body_stream(source),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(response.attributes.get(@mttp_core.protocol), Some("http/1.1"))
    assert_eq(text(response), "abcdef")
    guard fields(response) is Object(seen) else { fail("no fields") }
    assert_eq(seen.get("transfer-encoding"), Some(Json::string("chunked")))
  })
}

///|
async test "a large body streams through the paused buffer" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.h2c + "/big/5000000"),
      { timeout_ms: Some(20000), body: Stream(idle_ms=Some(5000)), },
    )
    guard response.body is Stream(stream) else { fail("not a stream") }
    let reader = stream.take()
    let mut total = 0
    while reader.read_some() is Some(piece) {
      total += piece.length()
    }
    assert_eq(total, 5000000)
  })
}

///|
async test "closing a body early leaves the backend usable" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let response = backend.send(
      @mttp_core.Request::get(server.h2c + "/big/5000000"),
      @mttp_core.SendOptions::default(),
    )
    guard response.body is Stream(stream) else { fail("not a stream") }
    let reader = stream.take()
    reader.read_some() |> ignore
    reader.close()
    reader.close()
    let again = backend.send(
      @mttp_core.Request::get(server.h2c + "/hello"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(text(again), "hello")
  })
}

///|
async test "one connection carries the requests to an https origin" {
  with_server(server => {
    let backend = tls_backend()
    defer backend.close()
    let ids = []
    @async.with_task_group(group => {
      for _ in 0..<4 {
        group.spawn_bg(() => {
          let response = backend.send(
            @mttp_core.Request::get(server.tls + "/session"),
            @mttp_core.SendOptions::default(),
          )
          ids.push(text(response))
        })
      }
    })
    let again = backend.send(
      @mttp_core.Request::get(server.tls + "/session"),
      @mttp_core.SendOptions::default(),
    )
    ids.push(text(again))
    // Concurrent and later requests alike on the first connection: over TLS
    // the backend has libcurl wait for ALPN rather than dial again.
    assert_eq(ids, ["1", "1", "1", "1", "1"])
  })
}

///|
async test "requests past SETTINGS_MAX_CONCURRENT_STREAMS still complete" {
  with_server(
    server => {
      let backend = h2c_backend()
      defer backend.close()
      let done = []
      @async.with_task_group(group => {
        for _ in 0..<4 {
          group.spawn_bg(() => {
            let response = backend.send(
              @mttp_core.Request::post(server.h2c + "/wait/200"),
              @mttp_core.SendOptions::default(),
            )
            done.push(text(response))
          })
        }
      })
      assert_eq(done, ["waited", "waited", "waited", "waited"])
    },
    max_streams=1,
  )
}

///|
async test "a cancelled send leaves the backend usable" {
  with_server(server => {
    let backend = h2c_backend()
    defer backend.close()
    let r = @async.with_timeout_opt(200, () => {
      backend.send(
        @mttp_core.Request::get(server.h2c + "/hang"),
        @mttp_core.SendOptions::default(),
      )
    })
    assert_true(r is None)
    let again = backend.send(
      @mttp_core.Request::get(server.h2c + "/hello"),
      @mttp_core.SendOptions::default(),
    )
    assert_eq(text(again), "hello")
  })
}

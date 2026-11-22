///|
/// A request body that never ends on its own: it gives `piece` each time
/// after `delay_ms`, so only an early response can end the exchange.
priv struct Endless {
  piece : Bytes
  delay_ms : Int32
  mut closed : Int32
}

///|
impl @mttp_core.BodyStream for Endless with fn read_some(self) {
  @async.sleep(self.delay_ms)
  Some(self.piece)
}

///|
impl @mttp_core.BodyStream for Endless with fn close(self) {
  self.closed += 1
}

///|
async test "an early final response stops the upload, over HTTP/2 and HTTP/1.1" {
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
    for case_ in [(h2, server.tls, "h2"), (h1, server.tls, "http/1.1")] {
      let (backend, base, protocol) = case_
      let source = Endless::{
        piece: Bytes::make(1000, b'x'),
        delay_ms: 20,
        closed: 0,
      }
      let response = backend.send(
        @mttp_core.Request::post(base + "/early/413").body_stream(source),
        { timeout_ms: Some(10000), body: Exchange(max_bytes=1 << 20), },
      )
      assert_eq(response.status, 413)
      assert_eq(response.attributes.get(@mttp_core.protocol), Some(protocol))
      assert_eq(text(response), "early")
      assert_eq(source.closed, 1)
      // The connection the upload was cut on is not used for what follows.
      let after = backend.send(
        @mttp_core.Request::get(base + "/hello"),
        @mttp_core.SendOptions::default(),
      )
      assert_eq(text(after), "hello")
    }
  })
}

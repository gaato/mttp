// The same port failure must report the same kind and phase whatever path
// the exchange takes: no body, a body sent with the head, a body uploaded
// concurrently (large in memory, or streamed), buffered or streamed
// response, fresh or reused connection.

///|
/// The request bodies, each taking another write path.
let shapes : Array[String] = ["none", "small", "large", "streamed"]

///|
fn shaped(h : Harness, shape : String) -> @http.Request {
  let post = @http.Request::post("http://example.test/")
  match shape {
    "none" => @http.Request::get("http://example.test/")
    "small" => post.body_bytes(b"small")
    "large" => post.body_bytes(Bytes::make(200000, b'x'))
    _ => post.body_stream(@sim.Feed::bytes(h.driver, [b"a", b"b"]))
  }
}

///|
/// A failure without a phase, as a port may raise one.
fn unphased(kind : @http.Kind) -> @http.TransportError {
  @http.TransportError(kind~, phase=Unknown, detail="injected")
}

///|
/// Sends `request` and reads the whole body: its text, or the failure.
async fn attempt(
  h : Harness,
  request : @http.Request,
  options : @http.SendOptions,
) -> Result[String, (@http.Kind, @http.Phase)] {
  Ok(fetch(h.client, request, options~)) catch {
    error => Err(kind_phase(error))
  }
}

///|
test "a port failure reports the same phase on every path" {
  let kinds : Array[@http.Kind] = [Network, Protocol]
  let modes = [exchange(), streaming()]
  // (where the failure is injected, the phase it must report)
  let points : Array[(String, @http.Phase)] = [
    ("head read", Head),
    ("body read", Body),
    ("write", Write),
  ]
  for kind in kinds {
    for point in points {
      let (at, phase) = point
      for shape in shapes {
        for options in modes {
          let h = Harness::new()
          let error = unphased(kind)
          match at {
            "head read" => ignore(h.scripted([Failure(error)]))
            "body read" =>
              ignore(
                h.scripted([
                  Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\na"),
                  Failure(error),
                ]),
              )
            _ => ignore(h.scripted([Eof], write_error=error))
          }
          h.run(() => {
            let result = attempt(h, shaped(h, shape), options)
            assert_eq(
              result,
              Err((kind, phase)),
              msg="\{at} \{shape} \{Repr(options)}",
            )
            h.finish()
          })
        }
      }
    }
  }
}

///|
test "a failure on a reused connection reports the same phase on every path" {
  for kind in [@http.Kind::Network, Protocol] {
    for shape in shapes {
      let h = Harness::new()
      h.run(() => {
        ignore(h.scripted([Chunk(ok("old")), Failure(unphased(kind))]))
        assert_eq(
          fetch(h.client, @http.Request::get("http://example.test/")),
          "old",
        )
        ignore(h.scripted([Chunk(ok("new"))]))
        let result = attempt(h, shaped(h, shape), exchange())
        // Only a replayable, idempotent request is resent, and only after
        // a network failure; every other failure keeps its phase.
        let expected : Result[String, (@http.Kind, @http.Phase)] = if shape ==
          "none" &&
          kind == Network {
          Ok("new")
        } else {
          Err((kind, Head))
        }
        assert_eq(result, expected, msg="\{Repr(kind)} \{shape}")
        h.finish()
      })
    }
  }
}

///|
test "a failure on the way to a proxy reports the same phase on every path" {
  let modes = [exchange(), streaming()]
  for kind in [@http.Kind::Network, Protocol] {
    // (the scheme, where the failure is injected, the phase to report)
    let points : Array[(String, String, @http.Phase)] = [
      ("https", "CONNECT answer", Dial),
      ("https", "CONNECT write", Dial),
      ("http", "forwarded head", Head),
      ("http", "forwarded write", Write),
    ]
    for point in points {
      let (scheme, at, phase) = point
      for shape in shapes {
        for options in modes {
          let h = Harness::new(config={
            ..@h1client.ClientConfig::default(),
            proxy: @h1client.ProxyConfig::fixed("http://proxy.test:3128"),
          })
          let error = unphased(kind)
          if at.has_suffix("write") {
            ignore(h.scripted([Eof], write_error=error))
          } else {
            ignore(h.scripted([Failure(error)]))
          }
          h.run(() => {
            let request = shaped(h, shape)
            let request = {
              ..request,
              url: request.url.replace(old="http:", new="\{scheme}:"),
            }
            assert_eq(
              attempt(h, request, options),
              Err((kind, phase)),
              msg="\{at} \{shape} \{Repr(options)}",
            )
            h.finish()
          })
          assert_eq(h.dialer.dialed, [("proxy.test", 3128)])
        }
      }
    }
  }
}

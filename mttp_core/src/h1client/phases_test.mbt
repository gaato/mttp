// The same port failure must report the same kind and phase whatever path
// the exchange takes: no body, a body sent with the head, a body uploaded
// concurrently (large in memory, or streamed), buffered or streamed
// response, fresh or reused connection.

///|
/// The request bodies, each taking another write path.
let shapes : Array[String] = ["none", "small", "large", "streamed"]

///|
fn shaped(h : Harness, shape : String) -> @mttp_core.Request {
  let post = @mttp_core.Request::post("http://example.test/")
  match shape {
    "none" => @mttp_core.Request::get("http://example.test/")
    "small" => post.body_bytes(b"small")
    "large" => post.body_bytes(Bytes::make(200000, b'x'))
    _ => post.body_stream(@sim.Feed::bytes(h.driver, [b"a", b"b"]))
  }
}

///|
/// A failure without a phase, as a port may raise one.
fn unphased(kind : @mttp_core.Kind) -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind~, phase=Unknown, detail="injected")
}

///|
/// Sends `request` and reads the whole body: its text, or the failure.
async fn attempt(
  h : Harness,
  request : @mttp_core.Request,
  options : @mttp_core.SendOptions,
) -> Result[String, (@mttp_core.Kind, @mttp_core.Phase)] {
  Ok(fetch(h.client, request, options~)) catch {
    error => Err(kind_phase(error))
  }
}

///|
test "a port failure reports the same phase on every path" {
  let kinds : Array[@mttp_core.Kind] = [Network, Protocol]
  let modes = [exchange(), streaming()]
  // (where the failure is injected, the phase it must report)
  let points : Array[(String, @mttp_core.Phase)] = [
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
  for kind in [@mttp_core.Kind::Network, Protocol] {
    for shape in shapes {
      let h = Harness::new()
      h.run(() => {
        ignore(h.scripted([Chunk(ok("old")), Failure(unphased(kind))]))
        assert_eq(
          fetch(h.client, @mttp_core.Request::get("http://example.test/")),
          "old",
        )
        ignore(h.scripted([Chunk(ok("new"))]))
        let result = attempt(h, shaped(h, shape), exchange())
        // Only a replayable, idempotent request is resent, and only after
        // a network failure; every other failure keeps its phase.
        let expected : Result[String, (@mttp_core.Kind, @mttp_core.Phase)] = if shape ==
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
  for kind in [@mttp_core.Kind::Network, Protocol] {
    // (the scheme, where the failure is injected, the phase to report)
    let points : Array[(String, String, @mttp_core.Phase)] = [
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

///|
/// RFC 9112, section 9.8: a connection whose TLS peer closed it without
/// close_notify ends where the framing delimits the message as one at EOF
/// does, with the same kind and phase on every path. Only a body the close
/// delimits is cut short by it.
test "an incomplete close reports what EOF reports on every path" {
  let modes = [exchange(), streaming()]
  let proxied = {
    ..@h1client.ClientConfig::default(),
    proxy: @h1client.ProxyConfig::fixed("http://proxy.test:3128"),
  }
  // (where the connection ends, the URL, the configuration, the steps
  // before the end, the outcome at EOF, the outcome at an incomplete close)
  let points : Array[
    (
      String,
      String,
      @h1client.ClientConfig,
      Array[@sim.ReadStep],
      Result[String, (@mttp_core.Kind, @mttp_core.Phase)],
      Result[String, (@mttp_core.Kind, @mttp_core.Phase)],
    ),
  ] = [
    (
      "before the head",
      "http://example.test/",
      @h1client.ClientConfig::default(),
      [],
      Err((Network, Head)),
      Err((Network, Head)),
    ),
    (
      "inside the head",
      "http://example.test/",
      @h1client.ClientConfig::default(),
      [Chunk(b"HTTP/1.1 200 OK\r\n")],
      Err((Network, Head)),
      Err((Network, Head)),
    ),
    (
      "before the CONNECT answer",
      "https://example.test/",
      proxied,
      [],
      Err((Network, Dial)),
      Err((Network, Dial)),
    ),
    (
      "inside a Content-Length body",
      "http://example.test/",
      @h1client.ClientConfig::default(),
      [Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\na")],
      Err((Protocol, Body)),
      Err((Protocol, Body)),
    ),
    (
      "inside a chunked body",
      "http://example.test/",
      @h1client.ClientConfig::default(),
      [
        Chunk(
          b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n",
        ),
      ],
      Err((Protocol, Body)),
      Err((Protocol, Body)),
    ),
    (
      "after a complete Content-Length body",
      "http://example.test/",
      @h1client.ClientConfig::default(),
      [
        Chunk(
          b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 1\r\n\r\na",
        ),
      ],
      Ok("a"),
      Ok("a"),
    ),
    (
      "after a close-delimited body",
      "http://example.test/",
      @h1client.ClientConfig::default(),
      [Chunk(b"HTTP/1.0 200 OK\r\n\r\na")],
      Ok("a"),
      Err((Protocol, Body)),
    ),
  ]
  for point in points {
    let (at, url, config, before, at_eof, at_incomplete) = point
    for shape in shapes {
      for options in modes {
        for
          end in [
            (@sim.ReadStep::Eof, at_eof),
            (incomplete_close(), at_incomplete),
          ] {
          let (tail, expected) = end
          let h = Harness::new(config~)
          ignore(h.scripted([..before, tail]))
          h.run(() => {
            let request = shaped(h, shape)
            let request = { ..request, url, }
            assert_eq(
              attempt(h, request, options),
              expected,
              msg="\{at} \{shape} \{Repr(options)}",
            )
            h.finish()
          })
        }
      }
    }
  }
}

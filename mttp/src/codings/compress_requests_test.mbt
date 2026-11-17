///|
fn upload(bytes~ : Bytes = b"hello") -> @mttp_core.Request {
  @mttp_core.Request::post("https://example.test/upload").body_bytes(
    bytes,
    content_type="application/json",
  )
}

///|
async fn decode_upload(request : @mttp_core.Request) -> Bytes {
  let wire = read_body(request.body)
  guard request.headers.get("content-encoding") is Some(name) else {
    return wire
  }
  let decoder = @codings.ContentDecoder::new(@codings.coding_plan(name))
  decoder.feed(wire)
  let out = Buffer()
  for ;; {
    match decoder.pull() {
      Slice(chunk) => out.write_bytes(chunk)
      NeedInput => decoder.end()
      Done => return out.to_bytes()
      @codings.Pulled::.. => fail("unexpected decoder result")
    }
  }
}

///|
test "compress_request buffers every coding with a replayable length and preserves metadata" {
  @driver.run_sync(() => {
    let key : @mttp_core.AttributeKey[Int32] = @mttp_core.AttributeKey::new(
      "request compression",
    )
    let original = upload()
      .header("content-length", "5")
      .header("transfer-encoding", "chunked")
      .attribute(key, 17)
    for coding in [@codings.Gzip, Deflate, Brotli, Zstd] {
      let sent = @codings.compress_request(original, coding, min_bytes=0)
      assert_true(sent.body is Bytes(_))
      assert_true(sent.body.is_replayable())
      assert_eq(
        sent.headers.get("content-length"),
        sent.body.length().map(n => n.to_string()),
      )
      assert_eq(sent.headers.get("transfer-encoding"), None)
      assert_eq(sent.headers.get("content-encoding"), Some(coding.name()))
      assert_eq(sent.meth, original.meth)
      assert_eq(sent.url, original.url)
      assert_eq(sent.attributes.get(key), Some(17))
      assert_eq(decode_upload(sent), b"hello")
      assert_eq(
        @codings.compress_request(sent, Gzip, min_bytes=0).body,
        sent.body,
      )
    }
    assert_eq(original.headers.get("content-length"), Some("5"))
    assert_eq(original.headers.get("content-encoding"), None)
    assert_eq(original.body, Bytes(b"hello"))
  })
}

///|
test "request compression matches default media ranges and skips protected encoded absent and empty bodies" {
  for
    (media, matches) in [
      ("application/json", true),
      ("Application/Problem+JSON; charset=utf-8", true),
      ("text/plain; charset=utf-8", true),
      ("text/html", true),
      ("application/xml", true),
      ("application/x-www-form-urlencoded", true),
      ("image/png", false),
      ("application/octet-stream", false),
      ("application/json-seq", false),
      ("application/+json", false),
      ("text/", false),
      ("text/plain/extra", false),
    ] {
    let sent = @codings.compress_request(
      upload().set_header("content-type", media),
      Gzip,
      min_bytes=0,
    )
    assert_eq(sent.headers.contains("content-encoding"), matches)
  }
  for
    name in [
      "Content-Digest", "Repr-Digest", "Content-MD5", "Signature-Input", "Content-Encoding",
    ] {
    let request = upload().header(name, "")
    let sent = @codings.compress_request(request, Gzip, min_bytes=0)
    assert_eq(sent.headers, request.headers)
    assert_eq(sent.body, request.body)
  }
  for
    request in [
      @mttp_core.Request::post("/").header("content-type", "text/plain"),
      upload(bytes=b""),
      @mttp_core.Request::post("/").body_bytes(b"hello"),
      upload().header("content-type", "text/plain"),
    ] {
    let sent = @codings.compress_request(request, Gzip, min_bytes=-1)
    assert_eq(sent.headers, request.headers)
    assert_eq(sent.body, request.body)
  }
}

///|
test "request threshold is inclusive negatives clamp and wrapper owns a copy of media patterns" {
  @driver.run_sync(() => {
    for (size, expected) in [(1023, false), (1024, true), (1025, true)] {
      let request = upload(bytes=Bytes::make(size, b'a'))
      let inner = fixture(@mttp_core.Response::new(200))
      let backend = @codings.CompressRequests::new(inner)
      ignore(backend.send(request, @mttp_core.SendOptions::default()))
      assert_eq(inner.sent[0].0.headers.contains("content-encoding"), expected)
      assert_eq(
        @codings.compress_request(request, Gzip).headers.contains(
          "content-encoding",
        ),
        expected,
      )
    }
    let types = ["IMAGE/*"]
    let inner = fixture(@mttp_core.Response::new(200))
    let backend = @codings.CompressRequests::new(
      inner,
      coding=Zstd,
      min_bytes=-1,
      content_types=types,
    )
    types[0] = "application/json"
    ignore(
      backend.send(
        upload().set_header("content-type", "image/svg+xml"),
        @mttp_core.SendOptions::default(),
      ),
    )
    assert_eq(inner.sent[0].0.headers.get("content-encoding"), Some("zstd"))
    let inner = fixture(@mttp_core.Response::new(200))
    ignore(
      @codings.CompressRequests::new(inner, min_bytes=0, content_types=[]).send(
        upload(),
        @mttp_core.SendOptions::default(),
      ),
    )
    assert_eq(inner.sent[0].0.headers.get("content-encoding"), None)
  })
}

///|
test "dictionary request codings fail Invalid even for ineligible bodies before taking a stream" {
  for coding in [@codings.Dcb, Dcz] {
    let feed = @sim.Feed::bytes(@driver.Driver::new(), [b"hello"])
    let request = upload().body_stream(feed)
    try @codings.compress_request(request, coding) catch {
      @mttp_core.TransportError(kind=Invalid, ..) => ()
      error => raise error
    } noraise {
      _ => fail("accepted dictionary coding")
    }
    try
      @codings.CompressRequests::new(
        fixture(@mttp_core.Response::new(200)),
        coding~,
      )
    catch {
      @mttp_core.TransportError(kind=Invalid, ..) => ()
      error => raise error
    } noraise {
      _ => fail("accepted dictionary wrapper")
    }
    assert_true(request.body.is_replayable())
    assert_eq(feed.reads(), 0)
    feed.close()
  }
}

///|
test "request streams opt in lazily respect known thresholds and close without prefetch" {
  @driver.run_sync(() => {
    for
      (enabled, length, expected) in [
        (false, None, false),
        (true, None, true),
        (true, Some(5L), true),
        (true, Some(4L), false),
        (true, Some(0L), false),
      ] {
      let feed = @sim.Feed::bytes(@driver.Driver::new(), [b"hello"])
      let request = upload()
        .body_stream(feed, length?, content_type="text/plain")
        .header("content-length", "5")
        .header("transfer-encoding", "chunked")
      let inner = fixture(@mttp_core.Response::new(200))
      let backend = @codings.CompressRequests::new(
        inner,
        streams=enabled,
        min_bytes=5,
      )
      ignore(backend.send(request, @mttp_core.SendOptions::default()))
      let sent = inner.sent[0].0
      assert_eq(feed.reads(), 0)
      assert_eq(sent.headers.contains("content-encoding"), expected)
      if expected {
        assert_eq(sent.body.length(), None)
        assert_eq(sent.headers.get("content-length"), None)
        assert_eq(sent.headers.get("transfer-encoding"), None)
      }
      if sent.body is Stream(stream) {
        stream.close()
        stream.close()
      }
      assert_eq(feed.closes(), 1)
      assert_eq(feed.reads(), 0)
    }
    let feed = @sim.Feed::bytes(@driver.Driver::new(), [b"hello"])
    let sent = @codings.compress_request(
      upload().body_stream(feed, content_type="text/plain"),
      Gzip,
    )
    assert_eq(feed.reads(), 0)
    assert_eq(decode_upload(sent), b"hello")
    assert_eq(feed.closes(), 1)
  })
}

///|
test "415 fallback requires an exclusion resends original once closes discarded body and forgets acceptance" {
  @driver.run_sync(() => {
    for
      (hint, fallback) in [
        (None, false),
        (Some("identity"), true),
        (Some(""), true),
        (Some("br"), true),
        (Some("gzip;q=0"), true),
        (Some("*;q=0"), true),
        (Some("gzip;q=0, *;q=1"), true),
        (Some("*"), false),
        (Some("gzip"), false),
        (Some("x-gzip"), false),
        (Some("gzip;q=0.1"), false),
        (Some("gzip;q=1, *;q=0"), false),
        (Some("gzip;q=bad"), false),
        (Some("g zip"), false),
        (Some(";q=0"), false),
        (Some("gzip;q=2"), false),
        (Some("gzip;q=0;foo=bar"), false),
        (Some(", identity, ,"), true),
      ] {
      let feed = @sim.Feed::bytes(@driver.Driver::new(), [b"rejected"])
      let headers = match hint {
        Some(hint) => @mttp_core.Headers::of([("accept-encoding", hint)])
        None => @mttp_core.Headers::empty()
      }
      let inner = fixture(
        @mttp_core.Response::new(
          415,
          headers~,
          body=Stream(@mttp_core.StreamBody::new(feed)),
        ),
      )
      let backend = @codings.CompressRequests::new(inner, min_bytes=0)
      let options : @mttp_core.SendOptions = {
        timeout_ms: Some(73),
        body: Stream(idle_ms=Some(9)),
      }
      let request = upload().header("content-length", "5")
      let response = backend.send(request, options)
      assert_eq(response.status, 415)
      assert_eq(inner.sent.length(), if fallback { 2 } else { 1 })
      assert_eq(feed.closes(), if fallback { 1 } else { 0 })
      assert_eq(feed.reads(), 0)
      if fallback {
        assert_eq(inner.sent[1].0.headers, request.headers)
        assert_eq(inner.sent[1].0.body, request.body)
        assert_eq(inner.sent[1].1, options)
      }
      assert_eq(inner.sent[0].1, options)
      response.close()
      ignore(backend.send(request, options))
      assert_eq(
        inner.sent[if fallback { 2 } else { 1 }].0.headers.get(
          "content-encoding",
        ),
        Some("gzip"),
      )
    }
    for
      (enabled, status, compress) in [
        (false, 415, true),
        (true, 400, true),
        (true, 415, false),
      ] {
      let inner = fixture(
        @mttp_core.Response::new(
          status,
          headers=@mttp_core.Headers::of([("accept-encoding", "identity")]),
        ),
      )
      ignore(
        @codings.CompressRequests::new(
          inner,
          min_bytes=if compress { 0 } else { 1024 },
          fallback_on_415=enabled,
        ).send(upload(), @mttp_core.SendOptions::default()),
      )
      assert_eq(inner.sent.length(), 1)
    }
  })
}

///|
test "415 never replays a taken compressed stream even when upstream rejects before reading" {
  @driver.run_sync(() => {
    let feed = @sim.Feed::bytes(@driver.Driver::new(), [b"hello"])
    let request = upload().body_stream(feed, content_type="application/json")
    let rejected = @sim.Feed::bytes(@driver.Driver::new(), [b"rejected"])
    let inner = fixture(
      @mttp_core.Response::new(
        415,
        headers=@mttp_core.Headers::of([("accept-encoding", "identity")]),
        body=Stream(@mttp_core.StreamBody::new(rejected)),
      ),
    )
    let response = @codings.CompressRequests::new(inner, streams=true).send(
      request,
      @mttp_core.SendOptions::default(),
    )
    assert_false(request.body.is_replayable())
    assert_eq(inner.sent.length(), 1)
    assert_eq(feed.reads(), 0)
    assert_eq(rejected.closes(), 0)
    response.close()
    if inner.sent[0].0.body is Stream(stream) {
      stream.close()
    }
    assert_eq(feed.closes(), 1)
  })
}

///|
test "CompressRequests satisfies Backend contract and passes both option modes unchanged" {
  @driver.run_sync(() => {
    @sim.check_backend_contract(
      () => {
        try! @codings.CompressRequests::new(
          fixture(@mttp_core.Response::new(200)),
        )
      },
      wrap=inner => try! @codings.CompressRequests::new(inner),
    )
    for
      body in [
        @mttp_core.BodyTiming::Exchange(max_bytes=17),
        Stream(idle_ms=Some(11)),
      ] {
      let inner = fixture(@mttp_core.Response::new(200))
      let backend = @codings.CompressRequests::new(inner, min_bytes=0)
      let options : @mttp_core.SendOptions = { timeout_ms: Some(42), body, }
      ignore(backend.send(upload(), options))
      assert_eq(inner.sent[0].1, options)
      backend.close()
      backend.close()
      assert_eq(inner.closes.val, 1)
    }
  })
}

///|
priv struct RequestRetryFixture {
  rejected : @mttp_core.Response
  feed : @sim.Feed
  closes_before_resend : Ref[Int32]
  sent : Array[@mttp_core.Request]
}

///|
impl @mttp_core.Backend for RequestRetryFixture with fn send(self, request, _) {
  self.sent.push(request)
  if self.sent.length() == 1 {
    self.rejected
  } else {
    self.closes_before_resend.val = self.feed.closes()
    @mttp_core.Response::new(200)
  }
}

///|
test "415 fallback works for each coding returns the resend and reclaims the rejected upgrade first" {
  @driver.run_sync(() => {
    for coding in [@codings.Gzip, Deflate, Brotli, Zstd] {
      let feed = @sim.Feed::bytes(@driver.Driver::new(), [b"rejected"])
      let upgrade = CodingUpgrade::{
        closes: Ref(0),
        slots: Ref(1),
        taken: false,
      }
      let rejected = @mttp_core.Response::new(
        415,
        headers=@mttp_core.Headers::of([("accept-encoding", "identity")]),
        body=Stream(@mttp_core.StreamBody::new(feed)),
      )
      let inner = RequestRetryFixture::{
        rejected: {
          ..rejected,
          attributes: rejected.attributes.put(@rt.upgraded, upgrade),
        },
        feed,
        closes_before_resend: Ref(0),
        sent: [],
      }
      let response = @codings.CompressRequests::new(inner, coding~, min_bytes=0).send(
        upload(),
        @mttp_core.SendOptions::default(),
      )
      assert_eq(response.status, 200)
      assert_eq(inner.sent.length(), 2)
      assert_eq(
        inner.sent[0].headers.get("content-encoding"),
        Some(coding.name()),
      )
      assert_eq(inner.sent[1].headers.get("content-encoding"), None)
      assert_eq(inner.closes_before_resend.val, 1)
      assert_eq(upgrade.closes.val, 1)
      assert_eq(upgrade.slots.val, 0)
    }
    let inner = fixture(
      @mttp_core.Response::new(
        415,
        headers=@mttp_core.Headers::of([("accept-encoding", "identity")]),
      ),
    )
    ignore(
      @codings.CompressRequests::new(inner, min_bytes=0).send(
        upload().header("content-encoding", "gzip"),
        @mttp_core.SendOptions::default(),
      ),
    )
    assert_eq(inner.sent.length(), 1)
    let inner = fixture(@mttp_core.Response::new(200))
    ignore(
      @codings.CompressRequests::new(inner, min_bytes=0, content_types=[
        "application/**",
      ]).send(upload(), @mttp_core.SendOptions::default()),
    )
    assert_eq(inner.sent[0].0.body, Bytes(b"hello"))
    for
      name in [
        "content-digest", "repr-digest", "content-md5", "signature-input",
      ] {
      let feed = @sim.Feed::bytes(@driver.Driver::new(), [b"hello"])
      let request = upload()
        .body_stream(feed, content_type="application/json")
        .header(name, "protected")
      let sent = @codings.compress_request(request, Gzip, min_bytes=0)
      assert_true(sent.body.is_replayable())
      assert_eq(sent.headers.get("content-encoding"), None)
      assert_eq(feed.reads(), 0)
      feed.close()
    }
  })
}

///|
test "compressed bytes and chunked streams round trip through a decoding HTTP server" {
  for coding in [@codings.Gzip, Deflate, Brotli, Zstd] {
    for streaming in [false, true] {
      let driver = @driver.Driver::new()
      driver.run(() => {
        let clock = @sim.SimClock::new(driver)
        let timer = @sim.SimTimer::new(driver)
        let coordination = @sim.SimCoordination::new(driver)
        let (client_conn, server_conn) = @sim.pair(coordination, chunk_bytes=7)
        let errors : Array[String] = []
        let seen = Ref(false)
        let serving = driver.spawn(() => {
          @h1server.serve_conn(
            server_conn,
            request => {
              let decoded = decode_upload(request) catch {
                error => {
                  errors.push(error.to_string())
                  return @mttp_core.Response::new(500)
                }
              }
              seen.val = true
              @mttp_core.Response::new(200, body=Bytes(decoded))
            },
            clock~,
            timer~,
            coordination~,
            scheme="http",
            auto_date=false,
            on_error=error => errors.push(error.to_string()),
          )
        })
        let engine = @h1client.Client::new(
          dialer=@sim.ScriptedDialer::new([client_conn]),
          clock~,
          timer~,
          coordination~,
          config=@h1client.ClientConfig::default(),
        )
        let backend = @codings.CompressRequests::new(
          engine,
          coding~,
          streams=true,
          min_bytes=0,
        )
        let source = @sim.Feed::bytes(driver, [b"hello", b" world"])
        let request = @mttp_core.Request::post("http://example.test/upload").body_bytes(
          b"hello world",
          content_type="text/plain",
        )
        let request = if streaming {
          request.body_stream(source, content_type="text/plain")
        } else {
          request
        }
        let response = backend.send(request, @mttp_core.SendOptions::default())
        assert_eq(response.status, 200)
        assert_eq(read_body(response.body), b"hello world")
        assert_true(seen.val)
        backend.close()
        assert_true(serving.wait())
        assert_eq(errors, [])
        if streaming {
          assert_eq(source.closes(), 1)
        } else {
          source.close()
        }
      })
    }
  }
}

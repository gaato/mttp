///|
priv struct BackendFixture {
  response : @http.Response
  sent : Array[(@http.Request, @http.SendOptions)]
  closes : Ref[Int32]
}

///|
impl @http.Backend for BackendFixture with fn send(self, request, options) {
  self.sent.push((request, options))
  self.response
}

///|
impl @http.Backend for BackendFixture with fn close(self) {
  self.closes.val += 1
}

///|
fn fixture(response : @http.Response) -> BackendFixture {
  { response, sent: [], closes: Ref(0), }
}

///|
fn encoded(bytes : Bytes, coding : @codings.Coding) -> Bytes raise {
  let encoder = @codings.ContentEncoder::new(coding)
  let out = Buffer()
  encoder.feed(bytes)
  let mut ended = false
  for ;; {
    match encoder.pull() {
      Slice(bytes) => out.write_bytes(bytes)
      NeedInput => {
        assert_false(ended)
        encoder.end()
        ended = true
      }
      Done => return out.to_bytes()
      @codings.Pulled::.. => fail("unexpected encoder result")
    }
  }
}

///|
async fn read_body(body : @http.Body) -> Bytes raise @http.TransportError {
  match body {
    Stream(stream) => @http.read_bounded(stream.take(), 2 * 1024 * 1024)
    _ => body.as_bytes().unwrap_or(b"")
  }
}

///|
test "Decompress negotiates only when absent and passes both SendOptions through unchanged" {
  @driver.run_sync(() => {
    let wire = encoded(b"hello", Gzip)
    let head = @http.Headers::of([
      ("content-encoding", "gzip"),
      ("content-length", wire.length().to_string()),
    ])
    for
      body in [
        @http.BodyTiming::Exchange(max_bytes=wire.length()),
        Stream(idle_ms=Some(7)),
      ] {
      let inner = fixture(
        @http.Response::new(200, headers=head, body=Bytes(wire)),
      )
      let backend = @codings.Decompress::new(inner)
      let options : @http.SendOptions = { timeout_ms: Some(42), body, }
      let response = backend.send(
        @http.Request::get("https://example.test/"),
        options,
      )
      assert_eq(inner.sent[0].1, options)
      assert_eq(
        inner.sent[0].0.headers.get("accept-encoding"),
        Some("gzip, deflate, br, zstd"),
      )
      assert_eq(response.headers.get("content-encoding"), None)
      assert_eq(response.headers.get("content-length"), None)
      assert_eq(read_body(response.body), b"hello")
      assert_eq(inner.response.headers, head)
      backend.close()
      backend.close()
      assert_eq(inner.closes.val, 1)
    }
    for value in ["identity", "gzip", ""] {
      let inner = fixture(
        @http.Response::new(200, headers=head, body=Bytes(wire)),
      )
      let response = @codings.Decompress::new(inner).send(
        @http.Request::get("/").header("accept-encoding", value),
        @http.SendOptions::default(),
      )
      assert_eq(inner.sent[0].0.headers.get("accept-encoding"), Some(value))
      assert_eq(response.headers, head)
      assert_eq(response.body, Bytes(wire))
    }
  })
}

///|
test "Decompress keeps unknown codings and bodyless metadata and removes only decoded outer codings" {
  @driver.run_sync(() => {
    let options = @http.SendOptions::default()
    for status in [100, 101, 199, 204, 304] {
      let original = @http.Response::new(
        status,
        headers=@http.Headers::of([
          ("content-encoding", "gzip"),
          ("content-length", "55"),
        ]),
      )
      let response = @codings.Decompress::new(fixture(original)).send(
        @http.Request::get("/"),
        options,
      )
      assert_eq(response.headers, original.headers)
    }
    let response = @http.Response::new(
      200,
      headers=@http.Headers::of([
        ("content-encoding", "gzip"),
        ("content-length", "55"),
      ]),
    )
    let head = @codings.Decompress::new(fixture(response)).send(
      @http.Request::new(Head, "/"),
      options,
    )
    assert_eq(head.headers, response.headers)
    let unknown = @http.Response::new(
      200,
      headers=@http.Headers::of([("content-encoding", "custom")]),
      body=Bytes(b"opaque"),
    )
    let response = @codings.Decompress::new(fixture(unknown)).send(
      @http.Request::get("/"),
      options,
    )
    assert_eq(response.body, unknown.body)
    assert_eq(response.headers, unknown.headers)
    let response = @http.Response::new(
      200,
      headers=@http.Headers::of([
        ("content-encoding", "custom"),
        ("content-encoding", "gzip"),
        ("content-length", "55"),
      ]),
      body=Bytes(encoded(b"opaque", Gzip)),
    )
    let response = @codings.Decompress::new(fixture(response)).send(
      @http.Request::get("/"),
      options,
    )
    assert_eq(response.headers.get_all("content-encoding"), ["custom"])
    assert_eq(response.headers.get("content-length"), None)
    assert_eq(read_body(response.body), b"opaque")
  })
}

///|
test "Decompress satisfies Backend validation and decoded BodyStream contracts" {
  @driver.run_sync(() => {
    @sim.check_backend_contract(() => {
      @codings.Decompress::new(fixture(@http.Response::new(200)))
    })
    let wire = encoded(b"hello", Gzip)
    let make = () => {
      let response = @codings.Decompress::new(
        fixture(
          @http.Response::new(
            200,
            headers=@http.Headers::of([("content-encoding", "gzip")]),
            body=Bytes(wire),
          ),
        ),
      ).send(@http.Request::get("/"), @http.SendOptions::default())
      guard response.body is Stream(stream) else {
        fail("expected decoded stream")
      }
      stream.take()
    }
    // The factory is async because constructing this body sends through a
    // Backend. The conformance checker takes an already constructed stream.
    let stream = make()
    @sim.check_body_stream_contract(() => stream, b"hello")
  })
}

///|
test "Decompress slices bombs at 64 KiB and a decoded reader closes at its own bound" {
  @driver.run_sync(() => {
    let driver = @driver.Driver::new()
    let wire = encoded(Bytes::make(131073, b'a'), Gzip)
    let feed = @sim.Feed::bytes(driver, [wire])
    let response = @http.Response::new(
      200,
      headers=@http.Headers::of([("content-encoding", "gzip")]),
      body=Stream(@http.StreamBody::new(feed)),
    )
    let response = @codings.Decompress::new(fixture(response)).send(
      @http.Request::get("/"),
      @http.SendOptions::default(),
    )
    guard response.body is Stream(stream) else { fail("expected decoded body") }
    let reader = stream.take()
    assert_eq(reader.read_some().map(Bytes::length), Some(65536))
    try @http.read_bounded(reader, 65536) catch {
      @http.TransportError(kind=TooLarge(limit=65536), phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("decoded bound ignored")
    }
    assert_true(feed.is_closed())
  })
}

///|
test "Decompress closes upstream on early close codec failure upstream failure and cancellation" {
  let driver = @driver.Driver::new(auto_advance=false)
  for mode in 0..<4 {
    let steps : Array[@sim.FeedStep] = match mode {
      0 => [Chunk(encoded(b"hello", Gzip))]
      1 => [Chunk(b"bad gzip")]
      2 =>
        [
          Fail(
            @http.TransportError(kind=Network, phase=Body, detail="upstream"),
          ),
        ]
      _ => [Wait(1000), Chunk(encoded(b"hello", Gzip))]
    }
    let feed = @sim.Feed::new(driver, steps)
    driver.run(() => {
      let response = @http.Response::new(
        200,
        headers=@http.Headers::of([("content-encoding", "gzip")]),
        body=Stream(@http.StreamBody::new(feed)),
      )
      let response = @codings.Decompress::new(fixture(response)).send(
        @http.Request::get("/"),
        @http.SendOptions::default(),
      )
      assert_eq(feed.reads(), 0)
      if mode == 0 {
        response.close()
        response.close()
      } else {
        let task = driver.spawn(() => {
          try read_body(response.body) catch {
            @http.TransportError(kind=Protocol, phase=Body, ..) if mode == 1 =>
              ()
            @http.TransportError(kind=Network, phase=Body, ..) if mode == 2 =>
              ()
            error => raise error
          } noraise {
            _ => fail("expected failure or cancellation")
          }
        })
        driver.pause()
        if mode == 3 {
          task.cancel()
        }
        assert_eq(task.wait(), mode != 3)
      }
      assert_eq(feed.closes(), 1)
    })
  }
}

///|
test "Decompress closes a response refused for too many content codings" {
  @driver.run_sync(() => {
    let feed = @sim.Feed::bytes(@driver.Driver::new(), [b"unread"])
    let response = @http.Response::new(
      200,
      headers=@http.Headers::of([
        ("content-encoding", Array::make(6, "gzip").join(",")),
      ]),
      body=Stream(@http.StreamBody::new(feed)),
    )
    try
      @codings.Decompress::new(fixture(response)).send(
        @http.Request::get("/"),
        @http.SendOptions::default(),
      )
    catch {
      @http.TransportError(kind=Protocol, phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("accepted six codings")
    }
    assert_eq(feed.closes(), 1)
    assert_eq(feed.reads(), 0)
  })
}

///|
test "compress negotiates each encoder and preserves representation attributes" {
  @driver.run_sync(() => {
    let attribute : @http.AttributeKey[Int32] = @http.AttributeKey::new(
      "coding-test",
    )
    for name in ["gzip", "deflate", "br"] {
      let original = {
        ..@http.Response::new(
          200,
          headers=@http.Headers::of([
            ("content-length", "1024"),
            ("etag", "\"strong\""),
            ("content-md5", "old"),
            ("content-digest", "old"),
          ]),
          body=Bytes(Bytes::make(1024, b'a')),
        ),
        attributes: @http.Attributes::empty().put(attribute, 7),
      }
      let handler = @codings.compress(_ => original)
      let response = handler(
        @http.Request::get("/").header("accept-encoding", name),
      )
      assert_eq(response.headers.get("content-encoding"), Some(name))
      assert_eq(response.headers.get("content-length"), None)
      assert_eq(response.headers.get("content-md5"), None)
      assert_eq(response.headers.get("content-digest"), None)
      assert_eq(response.headers.get("etag"), Some("W/\"strong\""))
      assert_eq(response.headers.get_all("vary"), ["Accept-Encoding"])
      assert_eq(response.attributes.get(attribute), Some(7))
      let wire = read_body(response.body)
      let decoder = @codings.ContentDecoder::new(@codings.coding_plan(name))
      decoder.feed(wire)
      let out = Buffer()
      for ;; {
        match decoder.pull() {
          Slice(bytes) => {
            assert_true(bytes.length() <= 65536)
            out.write_bytes(bytes)
          }
          NeedInput => decoder.end()
          Done => break
          @codings.Pulled::.. => fail("unknown decoder result")
        }
      }
      assert_eq(out.to_bytes(), Bytes::make(1024, b'a'))
    }
  })
}

///|
test "compress skips bodyless statuses HEAD ranges existing codings and no-transform" {
  @driver.run_sync(() => {
    let request = @http.Request::get("/").header("accept-encoding", "gzip")
    for status in [100, 101, 103, 199, 204, 206, 304] {
      let original = @http.Response::new(status, body=Bytes(b"unchanged"))
      let response = @codings.compress(_ => original, min_bytes=0)(request)
      assert_eq(response.body, original.body)
      assert_eq(response.headers, original.headers)
    }
    for
      (req, headers) in [
        (
          @http.Request::new(Head, "/").header("accept-encoding", "gzip"),
          @http.Headers::empty(),
        ),
        (request.header("range", "bytes=0-1"), @http.Headers::empty()),
        (request, @http.Headers::of([("content-encoding", "custom")])),
        (request, @http.Headers::of([("content-range", "bytes 0-1/4")])),
        (
          request,
          @http.Headers::of([("cache-control", "public, No-Transform")]),
        ),
      ] {
      let response = @codings.compress(
        _ => @http.Response::new(200, headers~, body=Bytes(b"unchanged")),
        min_bytes=0,
      )(req)
      assert_eq(response.body, Bytes(b"unchanged"))
      assert_eq(response.headers, headers)
    }
  })
}

///|
test "compress threshold is inclusive and Vary and weak validators are preserved" {
  @driver.run_sync(() => {
    for (size, compressed) in [(1023, false), (1024, true), (1025, true)] {
      let response = @codings.compress(_ => {
        @http.Response::new(200, body=Bytes(Bytes::make(size, b'a')))
      })(@http.Request::get("/").header("accept-encoding", "gzip"))
      assert_eq(response.headers.contains("content-encoding"), compressed)
      response.close()
    }
    for vary in ["*", "Accept-Encoding", "accept-encoding, origin"] {
      let response = @codings.compress(
        _ => {
          @http.Response::new(
            200,
            headers=@http.Headers::of([("vary", vary), ("etag", "W/\"weak\"")]),
            body=Bytes(b"x"),
          )
        },
        min_bytes=-1,
      )(@http.Request::get("/").header("accept-encoding", "gzip"))
      assert_eq(response.headers.get_all("vary"), [vary])
      assert_eq(response.headers.get("etag"), Some("W/\"weak\""))
      response.close()
    }
    let small = @codings.compress(_ => {
      @http.Response::new(200, body=Bytes(b"x"))
    })(@http.Request::get("/").header("accept-encoding", "gzip, identity;q=0"))
    assert_eq(small.headers.get("content-encoding"), Some("gzip"))
    small.close()
  })
}

///|
test "compress identity invalid negotiation and refusal close abandoned response bodies" {
  @driver.run_sync(() => {
    let response = @codings.compress(_ => {
      @http.Response::new(200, body=Bytes(b"plain"))
    })(@http.Request::get("/"))
    assert_eq(response.body, Bytes(b"plain"))
    for (value, status) in [("gzip;q=bad", 400), ("identity;q=0, *;q=0", 406)] {
      let feed = @sim.Feed::bytes(@driver.Driver::new(), [b"unread"])
      let response = @codings.compress(_ => {
        @http.Response::new(200, body=Stream(@http.StreamBody::new(feed)))
      })(@http.Request::get("/").header("accept-encoding", value))
      assert_eq(response.status, status)
      assert_eq(feed.closes(), 1)
      assert_eq(feed.reads(), 0)
    }
    let feed = @sim.Feed::bytes(@driver.Driver::new(), [b"unread"])
    let body = @http.StreamBody::new(feed)
    let _ = body.take()
    let response = @codings.compress(
      _ => @http.Response::new(200, body=Stream(body)),
      min_bytes=0,
    )(@http.Request::get("/").header("accept-encoding", "gzip"))
    assert_eq(response.status, 500)
    assert_eq(feed.closes(), 1)
  })
}

///|
test "compress streams without prefetch and its output is closed without reading upstream" {
  @driver.run_sync(() => {
    let feed = @sim.Feed::bytes(@driver.Driver::new(), [b"hello"])
    let response = @codings.compress(_ => {
      @http.Response::new(200, body=Stream(@http.StreamBody::new(feed)))
    })(@http.Request::get("/").header("accept-encoding", "gzip"))
    assert_eq(feed.reads(), 0)
    assert_eq(response.headers.get("content-encoding"), Some("gzip"))
    response.close()
    response.close()
    assert_eq(feed.reads(), 0)
    assert_eq(feed.closes(), 1)
  })
}

///|
test "router satisfies the shared Backend validation and close contract" {
  let router = @router.Router::new([])
  @driver.run_sync(() => @sim.check_backend_contract(() => router))
}

///|
test "readers return EOF after closing their response or retained request container" {
  let driver = @driver.Driver::new()
  for backend in [false, true] {
    let source = @sim.Feed::bytes(driver, [b"unused"])
    let ep = @endpoint.endpoint
      .get("/")
      .output(@endpoint.stream_body_out())
      .serve_public(_ => {
        Ok((None, @http.Body::Stream(@http.StreamBody::new(source))))
      })
    let router = @router.Router::new([ep])
    driver.run(() => {
      let response = if backend {
        router.send(@http.Request::get("/"), @http.SendOptions::default())
      } else {
        router.dispatch(@http.Request::get("/"))
      }
      guard response.body is Stream(body) else { fail("no stream") }
      let reader = body.take()
      response.close()
      assert_eq(reader.read_some(), None)
      assert_eq(source.closes(), 1)
      assert_eq(source.reads(), 0)
    })
  }
  let retained : Ref[&@http.BodyStream?] = Ref(None)
  let middleware : @router.Middleware = (request, _) => {
    if request.body is Stream(body) {
      retained.val = Some(
        body.take() catch {
          _ => return @http.Response::new(500)
        },
      )
    }
    @http.Response::new(204)
  }
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [middleware],
  })
  let feed = @sim.Feed::bytes(driver, [b"one", b"two"])
  driver.run(() => {
    assert_eq(
      router.send(
        @http.Request::post("/").body_stream(feed),
        @http.SendOptions::default(),
      ).status,
      204,
    )
    assert_eq(retained.val.unwrap().read_some(), None)
    assert_eq(feed.closes(), 1)
  })
}

///|
test "backend preflights streamed uploads before entering handlers" {
  let driver = @driver.Driver::new()
  let called = Ref(0)
  let ep = @endpoint.endpoint
    .post("/echo")
    .input(@endpoint.raw_body())
    .output(@endpoint.bytes_out())
  let router = @router.Router::new([
    ep.serve_public(bytes => {
      called.val += 1
      Ok(bytes)
    }),
  ])
  let feed = @sim.Feed::bytes(driver, [b"a", b"bc"])
  driver.run(() => {
    let response = router.send(
      @http.Request::post("/echo").body_stream(feed, length=3L),
      @http.SendOptions::default(),
    )
    assert_eq(response.body, @http.Body::Bytes(b"abc"))
    assert_eq(called.val, 1)
    for length in [None, Some(0L)] {
      let bad = @sim.Feed::new(driver, [
        Fail(
          @http.TransportError(kind=Network, phase=Pool, detail="before head"),
        ),
      ])
      try
        ignore(
          router.send(
            @http.Request::post("/echo").body_stream(bad, length?),
            @http.SendOptions::default(),
          ),
        )
      catch {
        @http.TransportError(kind=Network, ..) => ()
        error => raise error
      } noraise {
        _ => fail("failing upload dispatched")
      }
      assert_true(bad.is_closed())
    }
    let empty = @sim.Feed::bytes(driver, [])
    assert_eq(
      router.send(
        @http.Request::post("/echo").body_stream(empty, length=0L),
        @http.SendOptions::default(),
      ).body,
      @http.Body::Bytes(b""),
    )
    assert_eq(called.val, 2)
    let later = @sim.Feed::new(driver, [
      Chunk(b"x"),
      Fail(@http.TransportError(kind=Network, phase=Body, detail="after first")),
    ])
    assert_eq(
      router.send(
        @http.Request::post("/echo").body_stream(later),
        @http.SendOptions::default(),
      ).status,
      400,
    )
    assert_eq(called.val, 2)
    assert_eq(later.closes(), 1)
  })
  assert_true(feed.is_closed())
}

///|
test "backend response limits admit exact bytes and refuse crossing stream chunks" {
  let driver = @driver.Driver::new()
  let output = @sim.Feed::bytes(driver, [b"abc", b"d"])
  let router = @router.Router::new([
    @endpoint.endpoint
    .get("/bytes")
    .output(@endpoint.bytes_out())
    .serve_public(_ => Ok(b"abc")),
    @endpoint.endpoint
    .get("/stream")
    .output(@endpoint.stream_body_out())
    .serve_public(_ => {
      Ok((None, @http.Body::Stream(@http.StreamBody::new(output))))
    }),
    @endpoint.endpoint.get("/empty").serve_public(_ => Ok(())),
  ])
  driver.run(() => {
    let options = {
      ..@http.SendOptions::default(),
      body: Exchange(max_bytes=3),
    }
    assert_eq(
      router.send(@http.Request::get("/empty"), {
        ..options,
        body: Exchange(max_bytes=0),
      }).status,
      200,
    )
    try
      ignore(
        router.send(@http.Request::get("/bytes"), {
          ..options,
          body: Exchange(max_bytes=0),
        }),
      )
    catch {
      @http.TransportError(kind=TooLarge(limit=0), ..) => ()
      error => raise error
    } noraise {
      _ => fail("zero cap ignored")
    }
    assert_eq(
      router.send(@http.Request::get("/bytes"), options).body,
      @http.Body::Bytes(b"abc"),
    )
    try
      ignore(
        router.send(@http.Request::get("/bytes"), {
          ..options,
          body: Exchange(max_bytes=2),
        }),
      )
    catch {
      @http.TransportError(kind=TooLarge(limit=2), phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("byte cap ignored")
    }
    let response = router.send(@http.Request::get("/stream"), options)
    assert_eq(output.reads(), 0)
    guard response.body is Stream(body) else { fail("no stream") }
    let reader = body.take()
    assert_eq(reader.read_some(), Some(b"abc"))
    try ignore(reader.read_some()) catch {
      @http.TransportError(kind=TooLarge(limit=3), phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("crossing chunk exposed")
    }
    assert_eq(reader.read_some(), None)
    response.close()
    assert_eq(output.closes(), 1)
    assert_eq(
      router.send(@http.Request::get("/bytes"), {
        ..options,
        body: Stream(idle_ms=None),
      }).status,
      200,
    )
  })
}

///|
test "timed router sends require ports and enforce head exchange and idle deadlines" {
  let driver = @driver.Driver::new()
  let clock = @sim.SimClock::new(driver)
  let timer = @sim.SimTimer::new(driver)
  let head = @endpoint.endpoint
    .get("/head")
    .serve_public(_ => {
      driver.sleep(10)
      Ok(())
    })
  let feed = @sim.Feed::new(driver, [Wait(20), Chunk(b"x")])
  let stream = @endpoint.endpoint
    .get("/stream")
    .output(@endpoint.stream_body_out())
    .serve_public(_ => {
      Ok((None, @http.Body::Stream(@http.StreamBody::new(feed))))
    })
  let router = @router.Router::new([head, stream], clock~, timer~)
  let no_timer = @router.Router::new([])
  driver.run(() => {
    let options = { ..@http.SendOptions::default(), timeout_ms: Some(5), }
    let invalid = @sim.Feed::new(driver, [
      Fail(
        @http.TransportError(kind=Network, phase=Body, detail="timed preflight"),
      ),
    ])
    try
      ignore(
        router.send(@http.Request::post("/head").body_stream(invalid), options),
      )
    catch {
      @http.TransportError(kind=Network, ..) => ()
      error => raise error
    } noraise {
      _ => fail("timed source error replaced")
    }
    assert_eq(invalid.closes(), 1)
    try ignore(no_timer.send(@http.Request::get("/"), options)) catch {
      @http.TransportError(kind=Invalid, phase=Pool, ..) => ()
      error => raise error
    } noraise {
      _ => fail("missing timing ports accepted")
    }
    try ignore(router.send(@http.Request::get("/head"), options)) catch {
      @http.TransportError(kind=Timeout(ms=5), phase=Head, ..) => ()
      error => raise error
    } noraise {
      _ => fail("head deadline ignored")
    }
    let response = router.send(@http.Request::get("/stream"), options)
    try ignore(@client.read_body(response.body, 100)) catch {
      @http.TransportError(kind=Timeout(ms=5), phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("exchange deadline ignored")
    }
    assert_eq(feed.closes(), 1)
    // EOF is returned under a valid timer too, and Stream ends its head
    // deadline before later body reads (only the idle deadline remains).
    let fast = @sim.Feed::new(driver, [
      Wait(4),
      Chunk(b"x"),
      Wait(4),
      Chunk(b"y"),
    ])
    let ep = @endpoint.endpoint
      .get("/")
      .output(@endpoint.stream_body_out())
      .serve_public(_ => {
        Ok((None, @http.Body::Stream(@http.StreamBody::new(fast))))
      })
    let streaming = @router.Router::new([ep], clock~, timer~)
    let response = streaming.send(@http.Request::get("/"), {
      ..options,
      body: Stream(idle_ms=Some(5)),
    })
    assert_eq(@client.read_body(response.body, 100), b"xy")
    assert_eq(fast.closes(), 1)
    let slow = @sim.Feed::new(driver, [Wait(10), Chunk(b"z")])
    let ep = @endpoint.endpoint
      .get("/")
      .output(@endpoint.stream_body_out())
      .serve_public(_ => {
        Ok((None, @http.Body::Stream(@http.StreamBody::new(slow))))
      })
    let streaming = @router.Router::new([ep], clock~, timer~)
    let response = streaming.send(@http.Request::get("/"), {
      ..options,
      body: Stream(idle_ms=Some(3)),
    })
    try ignore(@client.read_body(response.body, 100)) catch {
      @http.TransportError(kind=Timeout(ms=3), phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("idle deadline ignored")
    }
    assert_eq(slow.closes(), 1)
  })
}

///|
test "exchange budget includes elapsed head time and caller pauses before reading" {
  let driver = @driver.Driver::new()
  let clock = @sim.SimClock::new(driver)
  let timer = @sim.SimTimer::new(driver)
  let feed = @sim.Feed::new(driver, [Wait(3), Chunk(b"x"), Wait(3), Chunk(b"y")])
  let ep = @endpoint.endpoint
    .get("/")
    .output(@endpoint.stream_body_out())
    .serve_public(_ => {
      driver.sleep(2)
      Ok((None, @http.Body::Stream(@http.StreamBody::new(feed))))
    })
  let router = @router.Router::new([ep], clock~, timer~)
  driver.run(() => {
    let response = router.send(@http.Request::get("/"), {
      ..@http.SendOptions::default(),
      timeout_ms: Some(8),
    })
    guard response.body is Stream(body) else { fail("no body") }
    let reader = body.take()
    assert_eq(reader.read_some(), Some(b"x"))
    driver.sleep(4)
    try ignore(reader.read_some()) catch {
      @http.TransportError(kind=Timeout(ms=0), phase=Body, ..) => ()
      error => raise error
    } noraise {
      _ => fail("expired budget ignored")
    }
    assert_eq(feed.closes(), 1)
  })
}

///|
test "backend cancellation unwinds a prefetched request and a pending response read" {
  let driver = @driver.Driver::new(auto_advance=false)
  let feed = @sim.Feed::new(driver, [Wait(100), Chunk(b"x")])
  let router = @router.Router::new([])
  driver.run(() => {
    let task = driver.spawn(() => {
      ignore(
        router.send(
          @http.Request::post("/").body_stream(feed),
          @http.SendOptions::default(),
        ),
      )
    })
    driver.pause()
    task.cancel()
    assert_false(task.wait())
    assert_eq(feed.closes(), 1)
    let source = @sim.Feed::new(driver, [Wait(100), Chunk(b"x")])
    let ep = @endpoint.endpoint
      .get("/")
      .output(@endpoint.stream_body_out())
      .serve_public(_ => {
        Ok((None, @http.Body::Stream(@http.StreamBody::new(source))))
      })
    let router = @router.Router::new([ep])
    let response = router.send(
      @http.Request::get("/"),
      @http.SendOptions::default(),
    )
    let task = driver.spawn(() => ignore(@client.read_body(response.body, 100)))
    driver.pause()
    task.cancel()
    assert_false(task.wait())
    assert_eq(source.closes(), 1)
  })
}

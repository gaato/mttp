///|
test "stub FIFO mismatch is terminal and does not consume expectation" {
  let stub = @testing.BackendStub::new()
    .expect(r => r.url == "/one", @testing.Canned::bytes(201, body=b"one"))
    .when(_ => true, @testing.Canned::bytes(200, body=b"fallback"))
  let opts = @mttp.SendOptions::default()
  @driver.run_sync(() => {
    let failed = try {
      let _ = stub.send(@mttp.Request::get("/wrong"), opts)
      false
    } catch {
      error => {
        assert_false(error.is_unsent())
        true
      }
    }
    assert_true(failed)
    assert_eq(stub.remaining(), 1)
    assert_eq(stub.send(@mttp.Request::get("/one"), opts).status, 201)
    assert_eq(
      stub.send(@mttp.Request::get("/two"), opts).body.as_bytes(),
      Some(b"fallback"),
    )
  })
  stub.verify()
  let recorded = stub.sent()
  assert_eq(recorded.length(), 3)
  recorded.clear()
  assert_eq(stub.sent().length(), 3)
  assert_eq(stub.sent()[0].options, opts)
}

///|
test "stub unmatched close failure factory and verify behavior" {
  let stub = @testing.BackendStub::new()
  let opts = @mttp.SendOptions::default()
  @driver.run_sync(() => {
    let failed = try {
      let _ = stub.send(@mttp.Request::get("/"), opts)
      false
    } catch {
      error => {
        assert_false(error.is_unsent())
        true
      }
    }
    assert_true(failed)
  })
  let _ = stub.expect(
    _ => true,
    Failure(@mttp.TransportError(kind=Network, phase=Head, detail="injected")),
  )
  let missing = try {
    stub.verify()
    false
  } catch {
    _ => true
  }
  assert_true(missing)
  @driver.run_sync(() => {
    let failed = try {
      let _ = stub.send(@mttp.Request::get("/"), opts)
      false
    } catch {
      @mttp.TransportError(kind=Network, ..) => true
      _ => false
    }
    assert_true(failed)
  })
  let _ = stub.when(
    r => r.url == "/factory",
    Factory((_, _) => @mttp.Response::new(202)),
  )
  assert_eq(
    @driver.run_sync(() => stub.send(@mttp.Request::get("/factory"), opts)).status,
    202,
  )
  stub.close()
  stub.close()
  let refused = try {
    let _ = @driver.run_sync(() => {
      stub.send(@mttp.Request::get("/factory"), opts)
    })
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}

///|
test "canned answers close a stream request body and a factory owns it" {
  let d = @driver.Driver::new()
  let stub = @testing.BackendStub::new()
    .expect(_ => true, @testing.Canned::bytes(201))
    .expect(
      _ => true,
      Failure(@mttp.TransportError(kind=Network, phase=Head, detail="fixture")),
    )
    .expect(
      _ => true,
      Factory((request, _) => {
        guard request.body is Stream(body) else {
          raise @mttp.TransportError(
            kind=Invalid,
            phase=Pool,
            detail="no stream",
          )
        }
        let read = @mttp.read_bounded(body.take(), 16)
        @mttp.Response::new(200, body=Bytes(read))
      }),
    )
  let feeds = []
  let upload = () => {
    let feed = @sim.Feed::bytes(d, [b"part"])
    feeds.push(feed)
    @mttp.Request::post("/").body_stream(feed)
  }
  d.run(() => {
    assert_eq(stub.send(upload(), @mttp.SendOptions::default()).status, 201)
    let failed = try {
      ignore(stub.send(upload(), @mttp.SendOptions::default()))
      false
    } catch {
      @mttp.TransportError(kind=Network, ..) => true
      error => raise error
    }
    assert_true(failed)
    let factory = stub.send(upload(), @mttp.SendOptions::default())
    assert_eq(factory.body.as_bytes(), Some(b"part"))
    // An unmatched send closes the body too.
    let unmatched = try {
      ignore(stub.send(upload(), @mttp.SendOptions::default()))
      false
    } catch {
      @mttp.TransportError(kind=Protocol, ..) => true
      error => raise error
    }
    assert_true(unmatched)
  })
  assert_eq(feeds.map(feed => (feed.reads(), feed.closes())), [
    (0, 1),
    (0, 1),
    (2, 1),
    (0, 1),
  ])
  // The records keep stream bodies as None.
  assert_eq(stub.sent().map(record => record.body), [None, None, None, None])
}

///|
test "stub FIFO mismatch is terminal and does not consume expectation" {
  let stub = @testing.BackendStub::new()
    .expect(r => r.url == "/one", @testing.Canned::bytes(201, body=b"one"))
    .when(_ => true, @testing.Canned::bytes(200, body=b"fallback"))
  let opts = @client.RequestOptions::default()
  @driver.run_sync(() => {
    let failed = try {
      let _ = stub.send(@model.Request::get("/wrong"), opts)
      false
    } catch {
      error => {
        assert_false(error.is_unsent())
        true
      }
    }
    assert_true(failed)
    assert_eq(stub.remaining(), 1)
    assert_eq(stub.send(@model.Request::get("/one"), opts).status, 201)
    assert_eq(
      stub.send(@model.Request::get("/two"), opts).body.as_bytes(),
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
  let opts = @client.RequestOptions::default()
  @driver.run_sync(() => {
    let failed = try {
      let _ = stub.send(@model.Request::get("/"), opts)
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
    Failure(@model.TransportError(kind=Network, phase=Head, detail="injected")),
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
      let _ = stub.send(@model.Request::get("/"), opts)
      false
    } catch {
      @model.TransportError(kind=Network, ..) => true
      _ => false
    }
    assert_true(failed)
  })
  let _ = stub.when(
    r => r.url == "/factory",
    Factory((_, _) => @model.Response::new(202)),
  )
  assert_eq(
    @driver.run_sync(() => stub.send(@model.Request::get("/factory"), opts)).status,
    202,
  )
  stub.close()
  stub.close()
  let refused = try {
    let _ = @driver.run_sync(() => {
      stub.send(@model.Request::get("/factory"), opts)
    })
    false
  } catch {
    _ => true
  }
  assert_true(refused)
}

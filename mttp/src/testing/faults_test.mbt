///|
fn injected() -> @model.TransportError {
  @model.TransportError(kind=Network, phase=Body, detail="injected")
}

///|
test "send faults stop before the inner backend and preserve close ownership" {
  let calls = Ref(0)
  let closed = Ref(0)
  let backend = @testing.fail_sends(
    @client.from_fn(
      (_, _) => {
        calls.val += 1
        @model.Response::new(200)
      },
      on_close=() => closed.val += 1,
    ),
    injected(),
    times=2,
  )
  @testing.run_sync(() => {
    for _ in 0..<2 {
      let failed = try {
        let _ = backend.send(
          @model.Request::get("/"),
          @client.RequestOptions::default(),
        )
        false
      } catch {
        @model.TransportError(kind=Network, phase=Body, ..) => true
        error => raise error
      }
      assert_true(failed)
    }
    assert_eq(calls.val, 0)
    let response = backend.send(
      @model.Request::get("/"),
      @client.RequestOptions::default(),
    )
    defer response.close()
    assert_eq(response.status, 200)
  })
  assert_eq(calls.val, 1)
  backend.close()
  backend.close()
  assert_eq(closed.val, 1)
}

///|
test "body faults cut chunks at the requested offset and close once" {
  for offset in [0, 1, 3, 4, 6] {
    let d = @driver.Driver::new()
    let source = @feed.Feed::bytes(d, [b"abc", b"def"])
    let stream = @testing.fail_after(source, offset, injected())
    let out = Buffer()
    let failed = try {
      d.run(() => {
        while stream.read_some() is Some(chunk) {
          out.write_bytes(chunk)
        }
      })
      false
    } catch {
      @model.TransportError(kind=Network, phase=Body, ..) => true
      error => raise error
    }
    assert_true(failed)
    assert_eq(out.to_bytes(), b"abcdef"[:offset].to_owned())
    assert_eq(d.run(() => stream.read_some()), None)
    stream.close()
    assert_eq(source.closes(), 1)
  }
}

///|
test "fault stream preserves earlier EOF and source failure and refuses negative offsets" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, [b"ok"])
  let stream = @testing.fail_after(source, 3, injected())
  assert_eq(d.run(() => @model.read_bounded(stream, 3)), b"ok")
  assert_eq(source.closes(), 1)
  let source = @feed.Feed::new(d, [
    Fail(@model.TransportError(kind=Closed, phase=Body, detail="source")),
  ])
  let stream = @testing.fail_after(source, 3, injected())
  let failed = try {
    let _ = d.run(() => stream.read_some())
    false
  } catch {
    @model.TransportError(kind=Closed, ..) => true
    error => raise error
  }
  assert_true(failed)
  assert_eq(source.closes(), 1)
  let source = @feed.Feed::bytes(d, [])
  let invalid = try {
    let _ = @testing.fail_after(source, -1, injected())
    false
  } catch {
    @model.TransportError(kind=Invalid, ..) => true
    error => raise error
  }
  assert_true(invalid)
  assert_eq(source.closes(), 1)
}

///|
test "fault stream rejects empty chunks and closes on cancellation" {
  let empty = BrokenStream::{ mode: 0, calls: 0, }
  let stream = @testing.fail_after(empty, 1, injected())
  let failed = try {
    let _ = @testing.run_sync(() => stream.read_some())
    false
  } catch {
    @model.TransportError(kind=Protocol, ..) => true
    error => raise error
  }
  assert_true(failed)
  let d = @driver.Driver::new()
  let source = @feed.Feed::new(d, [Wait(1000), Chunk(b"x")])
  let stream = @testing.fail_after(source, 1, injected())
  d.run(() => {
    let task = d.spawn(() => {
      let _ = stream.read_some()
    })
    d.pause()
    task.cancel()
    assert_false(task.wait())
  })
  assert_eq(source.closes(), 1)
}

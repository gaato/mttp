///|
fn injected() -> @mttp.TransportError {
  @mttp.TransportError(kind=Network, phase=Body, detail="injected")
}

///|
test "send faults stop before the inner backend and preserve close ownership" {
  let calls = Ref(0)
  let closed = Ref(0)
  let backend = @testing.fail_sends(
    @client.from_fn(
      (_, _) => {
        calls.val += 1
        @mttp.Response::new(200)
      },
      on_close=() => closed.val += 1,
    ),
    injected(),
    times=2,
  )
  @driver.run_sync(() => {
    for _ in 0..<2 {
      let failed = try {
        let _ = backend.send(
          @mttp.Request::get("/"),
          @mttp.SendOptions::default(),
        )
        false
      } catch {
        @mttp.TransportError(kind=Network, phase=Body, ..) => true
        error => raise error
      }
      assert_true(failed)
    }
    assert_eq(calls.val, 0)
    let response = backend.send(
      @mttp.Request::get("/"),
      @mttp.SendOptions::default(),
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
    let source = @sim.Feed::bytes(d, [b"abc", b"def"])
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
      @mttp.TransportError(kind=Network, phase=Body, ..) => true
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
  let source = @sim.Feed::bytes(d, [b"ok"])
  let stream = @testing.fail_after(source, 3, injected())
  assert_eq(d.run(() => @mttp.read_bounded(stream, 3)), b"ok")
  assert_eq(source.closes(), 1)
  let source = @sim.Feed::new(d, [
    Fail(@mttp.TransportError(kind=Closed, phase=Body, detail="source")),
  ])
  let stream = @testing.fail_after(source, 3, injected())
  let failed = try {
    let _ = d.run(() => stream.read_some())
    false
  } catch {
    @mttp.TransportError(kind=Closed, ..) => true
    error => raise error
  }
  assert_true(failed)
  assert_eq(source.closes(), 1)
  let source = @sim.Feed::bytes(d, [])
  let invalid = try {
    let _ = @testing.fail_after(source, -1, injected())
    false
  } catch {
    @mttp.TransportError(kind=Invalid, ..) => true
    error => raise error
  }
  assert_true(invalid)
  assert_eq(source.closes(), 1)
}

///|
/// A stream that breaks the contract with an empty chunk.
priv struct EmptyChunks {}

///|
impl @mttp.BodyStream for EmptyChunks with fn read_some(_) {
  Some(b"")
}

///|
impl @mttp.BodyStream for EmptyChunks with fn close(_) {
  ()
}

///|
test "fault stream rejects empty chunks and closes on cancellation" {
  let empty = EmptyChunks::{ }
  let stream = @testing.fail_after(empty, 1, injected())
  let failed = try {
    let _ = @driver.run_sync(() => stream.read_some())
    false
  } catch {
    @mttp.TransportError(kind=Protocol, ..) => true
    error => raise error
  }
  assert_true(failed)
  let d = @driver.Driver::new()
  let source = @sim.Feed::new(d, [Wait(1000), Chunk(b"x")])
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

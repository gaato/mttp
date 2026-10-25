///|
test "feed skips empties and has sticky EOF and idempotent close" {
  let d = @driver.Driver::new()
  let steps : Array[@feed.Step] = [
    Chunk(b""),
    Chunk(b"a"),
    End,
    Chunk(b"unreachable"),
  ]
  let feed = @feed.Feed::new(d, steps)
  steps.clear()
  d.run(() => {
    assert_eq(feed.read_some(), Some(b"a"))
    assert_eq(feed.read_some(), None)
    assert_eq(feed.read_some(), None)
  })
  feed.close()
  feed.close()
  assert_eq(feed.closes(), 1)
  assert_true(feed.is_closed())
  assert_eq(feed.reads(), 3)
  assert_eq(feed.cancellations(), 0)
}

///|
test "feed virtual wait and injected failure" {
  let d = @driver.Driver::new()
  let error = @model.TransportError(kind=Network, phase=Body, detail="injected")
  let feed = @feed.Feed::new(d, [Wait(10), Fail(error), Chunk(b"unreachable")])
  d.run(() => {
    let failed = try {
      let _ = feed.read_some()
      false
    } catch {
      @model.TransportError(kind=Network, ..) => true
      _ => false
    }
    assert_true(failed)
    assert_eq(d.now(), 10)
    assert_eq(feed.read_some(), None)
  })
  assert_eq(feed.cancellations(), 0)
}

///|
test "feed cancellation releases a bounded reader" {
  let d = @driver.Driver::new()
  let feed = @feed.Feed::new(d, [Wait(100), Chunk(b"late")])
  d.run(() => {
    let task = d.spawn(() => {
      let _ = @model.read_bounded(feed, 4)
    })
    d.pause()
    task.cancel()
    assert_false(task.wait())
  })
  assert_eq(feed.closes(), 1)
  assert_eq(feed.cancellations(), 1)
  assert_eq(d.pending_timers(), 0)
}

///|
test "feed explicit close while waiting ends the read" {
  let d = @driver.Driver::new()
  let feed = @feed.Feed::new(d, [Wait(10), Chunk(b"late")])
  d.run(() => {
    let reader = d.spawn(() => assert_eq(feed.read_some(), None))
    d.pause()
    feed.close()
    assert_true(reader.wait())
  })
  let bytes = @feed.Feed::bytes(d, [b"", b"ok"])
  d.run(() => {
    assert_eq(bytes.read_some(), Some(b"ok"))
    assert_eq(bytes.read_some(), None)
    bytes.close()
    assert_eq(bytes.read_some(), None)
  })
}

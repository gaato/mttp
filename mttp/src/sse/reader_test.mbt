///|
test "event reader preserves split events and metadata then closes at permanent EOF" {
  let d = @driver.Driver::new()
  let source = @sim.Feed::bytes(d, [
    b"id: 7\r", b"\ndata: hello\r\n\r\ndata: unfinished",
  ])
  let reader = @sse.SseReader::new(source)
  d.run(() => {
    assert_eq(reader.next_event(), Some(@sse.SseEvent::new("hello", id="7")))
    assert_eq(source.closes(), 0)
    assert_eq(reader.next_event(), None)
    assert_eq(reader.next_event(), None)
    reader.close()
  })
  assert_eq(source.reads(), 3)
  assert_eq(source.closes(), 1)
}

///|
test "event reader drains queued events then raises pending overflow before another read" {
  let d = @driver.Driver::new()
  let source = @sim.Feed::new(d, [
    Chunk(b"data: one\n\ndata: two\n\ndata: " + Bytes::make(32, b'x')),
    Wait(1_000_000),
    End,
  ])
  let reader = @sse.SseReader::new(source, max_event_bytes=16)
  d.run(() => {
    assert_eq(reader.next_event(), Some(@sse.SseEvent::new("one")))
    assert_eq(reader.next_event(), Some(@sse.SseEvent::new("two")))
    try {
      ignore(reader.next_event())
      fail("pending overflow lost")
    } catch {
      @mttp.TransportError(kind=TooLarge(limit~), phase~, ..) => {
        assert_eq(limit, 16)
        assert_eq(phase, Body)
      }
      error => raise error
    }
    assert_eq(reader.next_event(), None)
  })
  assert_eq(d.now(), 0L)
  assert_eq(source.reads(), 1)
  assert_eq(source.closes(), 1)
}

///|
test "event reader accepts its exact event bound and refuses one byte more" {
  for data in ["abcd", "abcde"] {
    let d = @driver.Driver::new()
    let source = @sim.Feed::bytes(d, [@sse.encode(@sse.SseEvent::new(data))])
    let reader = @sse.SseReader::new(source, max_event_bytes=10)
    let events = []
    let failed = try {
      d.run(() => reader.each(event => events.push(event.data)))
      false
    } catch {
      @mttp.TransportError(kind=TooLarge(limit~), phase~, ..) => {
        assert_eq(limit, 10)
        assert_eq(phase, Body)
        true
      }
      error => raise error
    }
    assert_eq(failed, data == "abcde")
    assert_eq(events, if failed { [] } else { ["abcd"] })
    assert_eq(source.reads(), if failed { 1 } else { 2 })
    assert_eq(source.closes(), 1)
  }
}

///|
test "event reader sentinel stops before delivery and discards queued events and overflow" {
  let d = @driver.Driver::new()
  let source = @sim.Feed::new(d, [
    Chunk(
      b"data: ok\n\ndata: [DONE]\n\ndata: never\n\ndata: " +
      Bytes::make(32, b'x'),
    ),
    Wait(1_000_000),
    End,
  ])
  let reader = @sse.SseReader::new(source, max_event_bytes=16)
  let events = []
  d.run(() => {
    reader.each(event => events.push(event.data), stop=event => {
      event.data == "[DONE]"
    })
    assert_eq(reader.next_event(), None)
  })
  assert_eq(events, ["ok"])
  assert_eq(d.now(), 0L)
  assert_eq(source.reads(), 1)
  assert_eq(source.closes(), 1)
}

///|
test "event reader closes on callback failure and preserves exception identity" {
  let d = @driver.Driver::new()
  let source = @sim.Feed::bytes(d, [b"data: one\n\ndata: two\n\n"])
  let reader = @sse.SseReader::new(source)
  let original = Failure("receive")
  d.run(() => {
    try {
      reader.each(_ => raise original)
      fail("callback failure lost")
    } catch {
      Failure(_) as error => assert_true(physical_equal(error, original))
      error => raise error
    }
    assert_eq(reader.next_event(), None)
  })
  assert_eq(source.reads(), 1)
  assert_eq(source.closes(), 1)
}

///|
test "event reader closes on transport failure and before its first pull" {
  let d = @driver.Driver::new()
  let original = @mttp.TransportError(kind=Network, phase=Body, detail="source")
  let source = @sim.Feed::new(d, [Fail(original)])
  let reader = @sse.SseReader::new(source)
  d.run(() => {
    try {
      ignore(reader.next_event())
      fail("transport failure lost")
    } catch {
      @mttp.TransportError(..) as error =>
        assert_true(physical_equal(error, original))
      error => raise error
    }
    assert_eq(reader.next_event(), None)
  })
  assert_eq(source.reads(), 1)
  assert_eq(source.closes(), 1)
  let unread = @sim.Feed::bytes(d, [b"data: unread\n\n"])
  let reader = @sse.SseReader::new(unread)
  reader.close()
  reader.close()
  d.run(() => assert_eq(reader.next_event(), None))
  assert_eq(unread.reads(), 0)
  assert_eq(unread.closes(), 1)
}

///|
test "event reader closes on cancellation during pulls and callbacks" {
  for in_callback in [false, true] {
    let d = @driver.Driver::new()
    let source = @sim.Feed::new(
      d,
      if in_callback {
        [Chunk(b"data: one\n\n")]
      } else {
        [Wait(1_000_000), End]
      },
    )
    let reader = @sse.SseReader::new(source)
    d.run(() => {
      let task = d.spawn(() => {
        if in_callback {
          reader.each(_ => d.sleep(1_000_000))
        } else {
          ignore(reader.next_event())
        }
      })
      d.pause()
      task.cancel()
      assert_false(task.wait())
      assert_true(task.is_cancelled())
      assert_eq(reader.next_event(), None)
    })
    assert_eq(source.reads(), 1)
    assert_eq(source.closes(), 1)
    assert_eq(source.cancellations(), if in_callback { 0 } else { 1 })
    assert_eq(d.now(), 0L)
  }
}

///|
fn[T] channel_on_driver(
  capacity? : Int32,
) -> (@endpoint.EventSender[T], @endpoint.EventStream[T]) raise {
  let coordination = @sim.SimCoordination::new(@driver.current())
  @endpoint.EventStream::channel(coordination~, capacity?)
}

///|
test "a channel delivers every value in the order sent" {
  @driver.run_sync(() => {
    let (sender, stream) = channel_on_driver(capacity=2)
    let accepted = []
    let producer = @driver.spawn(() => {
      for i in 1..<=5 {
        accepted.push(sender.send(i))
      }
      sender.close()
    })
    let read = []
    stream.each(n => read.push(n))
    assert_true(producer.wait())
    assert_eq(read, [1, 2, 3, 4, 5])
    assert_eq(accepted, [true, true, true, true, true])
  })
}

///|
test "a full channel holds the sender until a value is read" {
  @driver.run_sync(() => {
    let (sender, stream) = channel_on_driver(capacity=2)
    let sent = Ref(0)
    let producer = @driver.spawn(() => {
      for i in 1..<=3 {
        ignore(sender.send(i))
        sent.val += 1
      }
    })
    @driver.pause()
    assert_eq(sent.val, 2)
    assert_true(producer.is_parked())
    assert_eq(stream.next(), Some(1))
    @driver.pause()
    assert_eq(sent.val, 3)
    assert_true(producer.is_done())
    assert_eq(stream.next(), Some(2))
    assert_eq(stream.next(), Some(3))
  })
}

///|
test "a capacity below one holds one value" {
  @driver.run_sync(() => {
    let (sender, stream) = channel_on_driver(capacity=0)
    let sent = Ref(0)
    let producer = @driver.spawn(() => {
      for i in 1..<=2 {
        ignore(sender.send(i))
        sent.val += 1
      }
    })
    @driver.pause()
    assert_eq(sent.val, 1)
    assert_true(producer.is_parked())
    assert_eq(stream.next(), Some(1))
    assert_eq(stream.next(), Some(2))
    assert_true(producer.wait())
  })
}

///|
test "closing the stream wakes a waiting sender with false" {
  @driver.run_sync(() => {
    let (sender, stream) = channel_on_driver(capacity=1)
    let results = []
    let producer = @driver.spawn(() => {
      results.push(sender.send(1))
      // The channel is full: this send waits until the reader closes.
      results.push(sender.send(2))
      results.push(sender.send(3))
    })
    @driver.pause()
    assert_eq(results, [true])
    assert_true(producer.is_parked())
    stream.close()
    assert_true(producer.wait())
    assert_eq(results, [true, false, false])
    // The queued value was dropped with the stream.
    assert_eq(stream.next(), None)
  })
}

///|
test "a reader cancelled while it waits closes the stream for the sender" {
  @driver.run_sync(() => {
    let (sender, stream) = channel_on_driver()
    let reader = @driver.spawn(() => ignore(stream.next()), allow_failure=true)
    @driver.pause()
    assert_true(reader.is_parked())
    reader.cancel()
    ignore(reader.wait()) catch {
      _ => ()
    }
    assert_false(sender.send(1))
  })
}

///|
test "close lets the reader drain the queue, then ends it" {
  @driver.run_sync(() => {
    let (sender, stream) = channel_on_driver()
    assert_true(sender.send("a"))
    assert_true(sender.send("b"))
    sender.close()
    sender.fail(Failure("ignored: the stream already ended"))
    assert_false(sender.send("c"))
    assert_eq(stream.next(), Some("a"))
    assert_eq(stream.next(), Some("b"))
    assert_eq(stream.next(), None)
    assert_eq(stream.next(), None)
  })
}

///|
test "close wakes a reader waiting on an empty channel" {
  @driver.run_sync(() => {
    let (sender, stream) = channel_on_driver()
    let read : Ref[Int32?] = Ref(Some(0))
    let reader = @driver.spawn(() => read.val = stream.next())
    @driver.pause()
    assert_true(reader.is_parked())
    sender.close()
    assert_true(reader.wait())
    assert_eq(read.val, None)
  })
}

///|
test "fail delivers the queued values, then raises the error once" {
  @driver.run_sync(() => {
    let (sender, stream) = channel_on_driver()
    assert_true(sender.send(1))
    sender.fail(Failure("upstream failed"))
    sender.close()
    assert_false(sender.send(2))
    assert_eq(stream.next(), Some(1))
    let raised = try {
      ignore(stream.next())
      "no error"
    } catch {
      Failure(message) => message
      _ => "other"
    }
    assert_eq(raised, "upstream failed")
    // The failed pull closed the stream.
    assert_eq(stream.next(), None)
  })
}

///|
test "a mapped channel stream keeps order and passes its close to the sender" {
  @driver.run_sync(() => {
    let (sender, stream) = channel_on_driver(capacity=1)
    let mapped = stream.map(n => "event \{n}")
    let results = []
    let producer = @driver.spawn(() => {
      for i in 1..<=3 {
        results.push(sender.send(i))
      }
    })
    assert_eq(mapped.next(), Some("event 1"))
    assert_eq(mapped.next(), Some("event 2"))
    @driver.pause()
    // The third value is queued; the mapped stream is closed before it is
    // read, which closes the channel's stream too.
    mapped.close()
    assert_true(producer.wait())
    assert_eq(results, [true, true, true])
    assert_false(sender.send(4))
  })
}

///|
test "senders waiting on a full channel each get in, in turn" {
  @driver.run_sync(() => {
    let (sender, stream) = channel_on_driver(capacity=1)
    assert_true(sender.send(1))
    let first = @driver.spawn(() => ignore(sender.send(2)))
    let second = @driver.spawn(() => ignore(sender.send(3)))
    @driver.pause()
    assert_true(first.is_parked())
    assert_true(second.is_parked())
    let read = []
    for _ in 0..<3 {
      read.push(stream.next().unwrap())
    }
    assert_eq(read, [1, 2, 3])
    assert_true(first.wait())
    assert_true(second.wait())
  })
}

///|
test "closing the stream from another task ends a waiting read" {
  @driver.run_sync(() => {
    let (sender, stream) = channel_on_driver()
    let read : Ref[Int32?] = Ref(Some(0))
    let reader = @driver.spawn(() => read.val = stream.next())
    @driver.pause()
    assert_true(reader.is_parked())
    // A server shutting down closes the body while its pull waits.
    stream.close()
    assert_true(reader.wait())
    assert_eq(read.val, None)
    assert_false(sender.send(1))
  })
}

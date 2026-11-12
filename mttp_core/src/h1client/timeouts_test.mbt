///|
/// A connection whose writes never finish until it is closed.
priv struct StallConn {
  signal : &@rt.Signal
  mut closes : Int32
}

///|
impl @rt.Conn for StallConn with fn read(self, max_len~) {
  ignore(max_len)
  self.signal.wait()
  None
}

///|
impl @rt.Conn for StallConn with fn write(self, _) {
  self.signal.wait()
  raise @mttp_core.TransportError(kind=Network, phase=Write, detail="closed")
}

///|
impl @rt.Conn for StallConn with fn close(self) {
  if self.closes == 0 {
    self.signal.notify()
  }
  self.closes += 1
}

///|
fn with_config(
  f : (@h1client.ClientConfig) -> @h1client.ClientConfig,
) -> @h1client.ClientConfig {
  f(@h1client.ClientConfig::default())
}

///|
test "a response head that never comes times out under the read limit" {
  let h = Harness::new(
    config=with_config(c => {
      ..c,
      read_timeout_ms: Some(5),
      max_connections: Some(1),
    }),
  )
  let blocked = h.scripted([Wait(h.coordination.signal())])
  ignore(h.scripted([Chunk(b"HTTP/1.1 204 No Content\r\n\r\n")]))
  h.run(() => {
    assert_eq(
      failing(() => {
        ignore(fetch(h.client, @mttp_core.Request::get("http://example.test/")))
      }),
      (Timeout(ms=5), Head),
    )
    assert_eq(h.driver.now(), 5L)
    assert_eq(blocked.closes(), 1)
    // The slot was released: the next request gets a connection.
    assert_eq(
      fetch(h.client, @mttp_core.Request::get("http://example.test/")),
      "",
    )
    h.finish()
  })
}

///|
test "the attempt deadline covers a buffered body but ends at a streamed head" {
  for streamed in [false, true] {
    let h = Harness::new()
    let late = h.coordination.signal()
    ignore(
      h.scripted([
        Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nab"),
        Wait(late),
        Chunk(b"cd"),
      ]),
    )
    h.run(() => {
      let notifier = h.driver.spawn(() => {
        h.driver.sleep(60)
        late.notify()
      })
      let options = if streamed {
        streaming(timeout_ms=50)
      } else {
        exchange(timeout_ms=50)
      }
      let result = Ok(
        fetch(
          h.client,
          @mttp_core.Request::get("http://example.test/"),
          options~,
        ),
      ) catch {
        error => Err(kind_phase(error))
      }
      if streamed {
        assert_eq(result, Ok("abcd"))
        assert_eq(h.driver.now(), 60L)
      } else {
        assert_eq(result, Err((Timeout(ms=50), Body)))
        assert_eq(h.driver.now(), 50L)
      }
      ignore(notifier.wait())
      h.finish()
    })
  }
}

///|
test "each streamed read waits at most the idle or the read limit" {
  let rows : Array[(Int32?, Int32?, Int32)] = [
    (Some(20), None, 20),
    (Some(20), Some(30), 20),
    (Some(20), Some(10), 10),
    (None, Some(10), 10),
  ]
  for row in rows {
    let (idle, read, expected) = row
    let h = Harness::new(
      config=with_config(c => { ..c, read_timeout_ms: read, }),
    )
    ignore(
      h.scripted([
        Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nab"),
        Wait(h.coordination.signal()),
      ]),
    )
    h.run(() => {
      let response = h.client.send(
        @mttp_core.Request::get("http://example.test/"),
        streaming(idle_ms?=idle),
      )
      guard response.body is Stream(body) else { fail("expected a stream") }
      let stream = body.take()
      assert_eq(stream.read_some(), Some(b"ab"))
      let start = h.driver.now()
      assert_eq(
        failing(() => ignore(stream.read_some())),
        (Timeout(ms=expected), Body),
      )
      assert_eq(h.driver.now() - start, expected.to_int64())
      // A failed read closed the connection; later reads are EOF.
      assert_eq(stream.read_some(), None)
      h.finish()
    })
  }
}

///|
test "cancelling a send or a body read closes the connection and frees the slot" {
  for mode in 0..<2 {
    let h = Harness::new(
      config=with_config(c => { ..c, max_connections: Some(1), }),
    )
    let blocked = if mode == 0 {
      h.scripted([Wait(h.coordination.signal())])
    } else {
      h.scripted([
        Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nab"),
        Wait(h.coordination.signal()),
      ])
    }
    ignore(h.scripted([Chunk(ok("next"))]))
    h.run(() => {
      let task = h.driver.spawn(() => {
        ignore(fetch(h.client, @mttp_core.Request::get("http://example.test/")))
      })
      h.driver.pause()
      assert_true(task.is_parked())
      task.cancel()
      assert_false(task.wait())
      assert_eq(blocked.closes(), 1)
      assert_eq(h.client.idle_connections(), 0)
      assert_eq(
        fetch(h.client, @mttp_core.Request::get("http://example.test/")),
        "next",
      )
      h.finish()
    })
  }
}

///|
test "a concurrent read of one body is refused and discards the connection" {
  let h = Harness::new()
  let late = h.coordination.signal()
  let conn = h.scripted([
    Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n"),
    Wait(late),
    Chunk(b"ok"),
  ])
  h.run(() => {
    let response = h.client.send(
      @mttp_core.Request::get("http://example.test/"),
      exchange(),
    )
    guard response.body is Stream(body) else { fail("expected a stream") }
    let stream = body.take()
    let mut first = None
    let reader = h.driver.spawn(() => {
      first = Some(failing(() => ignore(stream.read_some())))
    })
    h.driver.pause()
    // Concurrent reads are outside the BodyStream contract: the second one
    // is refused, and the refusal closes the body under the first.
    assert_eq(failing(() => ignore(stream.read_some())), (Invalid, Body))
    ignore(reader.wait())
    assert_eq(first, Some((Protocol, Body)))
    assert_eq(conn.closes(), 1)
    assert_eq(h.client.idle_connections(), 0)
    h.finish()
  })
}

///|
test "every phase reports the limit that ran out, when it ran out" {
  let config = with_config(c => {
    ..c,
    max_connections: Some(1),
    pool_timeout_ms: Some(100),
    connect_timeout_ms: Some(200),
    write_timeout_ms: Some(300),
    read_timeout_ms: Some(400),
  })
  let phases : Array[(@mttp_core.Phase, Int32)] = [
    (Pool, 100),
    (Dial, 200),
    (Write, 300),
    (Head, 400),
    (Body, 400),
  ]
  for row in phases {
    let (phase, expected) = row
    let h = Harness::new(config~)
    match phase {
      Pool => ignore(h.scripted([Chunk(ok("held"))]))
      Dial => h.hang()
      Write =>
        h.dialer.queue.push(
          Hand(StallConn::{ signal: h.coordination.signal(), closes: 0, }),
        )
      Head => ignore(h.scripted([Wait(h.coordination.signal())]))
      _ =>
        ignore(
          h.scripted([
            Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n"),
            Wait(h.coordination.signal()),
          ]),
        )
    }
    h.run(() => {
      let held = if phase == Pool {
        Some(
          h.client.send(@mttp_core.Request::get("http://a.test/"), exchange()),
        )
      } else {
        None
      }
      let start = h.driver.now()
      assert_eq(
        failing(() => {
          ignore(
            fetch(
              h.client,
              @mttp_core.Request::get("http://a.test/"),
              options=exchange(timeout_ms=1000),
            ),
          )
        }),
        (Timeout(ms=expected), phase),
      )
      assert_eq(h.driver.now() - start, expected.to_int64())
      if held is Some(response) {
        response.close()
      }
      h.finish()
    })
  }
}

///|
test "the attempt deadline caps the phase that is running when it ends" {
  // (head arrival, read limit, outcome, time of the outcome)
  let rows : Array[(Int32, Int32?, (@mttp_core.Kind, @mttp_core.Phase), Int64)] = [
    // The body read starts at 800 with 200 ms of the deadline left.
    (800, None, (Timeout(ms=1000), Body), 1000L),
    (999, None, (Timeout(ms=1000), Body), 1000L),
    // A shorter read limit ends first and is the one reported.
    (300, Some(400), (Timeout(ms=400), Body), 700L),
    (700, Some(400), (Timeout(ms=400), Head), 400L),
  ]
  for row in rows {
    let (arrival, read, expected, at) = row
    let h = Harness::new(
      config=with_config(c => { ..c, read_timeout_ms: read, }),
    )
    let late = h.coordination.signal()
    ignore(
      h.scripted([
        Wait(late),
        Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\na"),
        Wait(h.coordination.signal()),
      ]),
    )
    h.run(() => {
      let notifier = h.driver.spawn(() => {
        h.driver.sleep(arrival)
        late.notify()
      })
      assert_eq(
        failing(() => {
          ignore(
            fetch(
              h.client,
              @mttp_core.Request::get("http://a.test/"),
              options=exchange(timeout_ms=1000),
            ),
          )
        }),
        expected,
      )
      assert_eq(h.driver.now(), at)
      notifier.cancel()
      ignore(notifier.wait())
      h.finish()
    })
  }
}

///|
test "deadlines survive extreme and backward clocks" {
  // A deadline past the end of time saturates instead of wrapping around.
  let driver = @driver.Driver::new(start_ms=9223372036854775800L)
  let conn = @sim.ScriptedConn::new([Chunk(ok("late"))])
  let client = @h1client.Client::new(
    dialer=@sim.ScriptedDialer::new([conn]),
    clock=@sim.SimClock::new(driver),
    timer=@sim.SimTimer::new(driver),
    coordination=@sim.SimCoordination::new(driver),
    config=@h1client.ClientConfig::default(),
  )
  driver.run(() => {
    assert_eq(
      fetch(
        client,
        @mttp_core.Request::get("http://a.test/"),
        options=exchange(timeout_ms=1000),
      ),
      "late",
    )
    client.close()
  })
  // A wall clock that jumps back mid-exchange leaves more time, not less.
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
  let clock = @sim.FakeClock::new(start_unix_ms=1000L)
  let late = coordination.signal()
  let conn = @sim.ScriptedConn::new([
    Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\na"),
    Wait(late),
    Chunk(b"b"),
  ])
  let client = @h1client.Client::new(
    dialer=@sim.ScriptedDialer::new([conn]),
    clock~,
    timer=@sim.SimTimer::new(driver),
    coordination~,
    config=@h1client.ClientConfig::default(),
  )
  driver.run(() => {
    let response = client.send(
      @mttp_core.Request::get("http://a.test/"),
      exchange(timeout_ms=50),
    )
    guard response.body is Stream(body) else { fail("expected a stream") }
    let stream = body.take()
    assert_eq(stream.read_some(), Some(b"a"))
    clock.advance(-2147483647)
    let notifier = driver.spawn(() => {
      driver.sleep(10)
      late.notify()
    })
    assert_eq(stream.read_some(), Some(b"b"))
    assert_eq(stream.read_some(), None)
    ignore(notifier.wait())
    client.close()
  })
  assert_eq(conn.closes(), 1)
}

///|
test "a body read started after the attempt deadline fails at once" {
  let h = Harness::new()
  let never = h.coordination.signal()
  let conn = h.scripted([
    Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\na"),
    Wait(never),
  ])
  h.run(() => {
    let response = h.client.send(
      @mttp_core.Request::get("http://example.test/"),
      exchange(timeout_ms=100),
    )
    guard response.body is Stream(body) else { fail("expected a stream") }
    let stream = body.take()
    assert_eq(stream.read_some(), Some(b"a"))
    h.driver.sleep(150)
    assert_eq(
      failing(() => ignore(stream.read_some())),
      (Timeout(ms=100), Body),
    )
    assert_eq(h.driver.now(), 150L)
    assert_eq(conn.closes(), 1)
    h.finish()
  })
}

///|
test "closing the client while a stream's first piece is read refuses the send" {
  let h = Harness::new()
  h.run(() => {
    let feed = @sim.Feed::new(h.driver, [Wait(10), Chunk(b"x")])
    let closer = h.driver.spawn(() => {
      h.driver.sleep(5)
      h.client.close()
    })
    assert_eq(
      failing(() => {
        ignore(
          fetch(
            h.client,
            @mttp_core.Request::post("http://example.test/").body_stream(feed),
          ),
        )
      }),
      (Closed, Pool),
    )
    assert_eq(feed.closes(), 1)
    ignore(closer.wait())
  })
  assert_eq(h.dialer.dialed, [])
}

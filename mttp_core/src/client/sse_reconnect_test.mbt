// Client::sse_reconnecting on a Driver's virtual clock: each connection is
// one scripted response, and every request records its time and its
// Last-Event-ID.

///|
/// One connection's answer: a response built on the Driver, or a failure.
priv enum SseStep {
  Events(Array[@sim.FeedStep])
  Answer(Int32, Array[(String, String)])
  Refuse(@mttp_core.TransportError)
}

///|
priv struct SseServer {
  driver : @driver.Driver
  steps : Array[SseStep]
  /// (virtual time, Last-Event-ID, Accept) of every request.
  seen : Array[(Int64, String?, String?)]
  feeds : Array[@sim.Feed]
}

///|
fn SseServer::new(driver : @driver.Driver, steps : Array[SseStep]) -> SseServer {
  { driver, steps, seen: [], feeds: [], }
}

///|
fn SseServer::client(
  self : SseServer,
  random~ : Double = 0.5,
) -> @client.Client {
  @client.Client::new(
    @client.from_fn((request, _) => {
      self.seen.push(
        (
          self.driver.now(),
          request.headers.get("last-event-id"),
          request.headers.get("accept"),
        ),
      )
      let index = self.seen.length() - 1
      guard index < self.steps.length() else {
        abort("unexpected connection \{index}")
      }
      match self.steps[index] {
        Events(script) => {
          let feed = @sim.Feed::new(self.driver, script)
          self.feeds.push(feed)
          @mttp_core.Response::new(
            200,
            headers=@mttp_core.Headers::of([
              ("content-type", "text/event-stream; charset=utf-8"),
            ]),
            body=Stream(@mttp_core.StreamBody::new(feed)),
          )
        }
        Answer(status, headers) =>
          @mttp_core.Response::new(
            status,
            headers=@mttp_core.Headers::of(headers),
            body=Bytes(b"why"),
          )
        Refuse(error) => raise error
      }
    }),
    @sim.SimClock::new(self.driver),
    random=() => random,
  )
}

///|
fn sse_policy(max_attempts? : Int32) -> @client.ReconnectPolicy {
  {
    ..@client.ReconnectPolicy::default(),
    backoff: { base_ms: 100, max_ms: 10_000, jitter: NoJitter, },
    max_attempts,
  }
}

///|
fn reset_error() -> @mttp_core.TransportError {
  @mttp_core.TransportError(kind=Network, phase=Body, detail="reset")
}

///|
test "event streams reconnect after EOF and a failure with Last-Event-ID and retry" {
  let d = @driver.Driver::new()
  let server = SseServer::new(d, [
    Events([Chunk(b"retry: 2000\nid: 1\ndata: a\n\n"), End]),
    Events([
      Wait(30),
      Chunk(b"id: 2\ndata: b\n\nid: 3\n\n"),
      Fail(reset_error()),
    ]),
    Refuse(
      @mttp_core.TransportError(kind=Connect, phase=Dial, detail="refused"),
    ),
    Events([Chunk(b"data: c\n\n"), End]),
    Answer(204, []),
  ])
  let client = server.client()
  let received = []
  let end = d.run(() => {
    client.sse_reconnecting(
      @mttp_core.Request::get("/events").header("last-event-id", "0"),
      event => received.push((event.id, event.data)),
      policy=sse_policy(),
    )
  })
  assert_true(end is NoContent)
  assert_eq(received, [(Some("1"), "a"), (Some("2"), "b"), (None, "c")])
  // The retry: field sets the first wait and floors the later ones; the
  // id-only block counts, and an id survives a connection that sent none.
  // The second connection lived 30 ms, the third never connected.
  assert_eq(server.seen, [
    (0L, Some("0"), Some("text/event-stream")),
    (2000L, Some("1"), Some("text/event-stream")),
    (4030L, Some("3"), Some("text/event-stream")),
    (6030L, Some("3"), Some("text/event-stream")),
    (8030L, Some("3"), Some("text/event-stream")),
  ])
  assert_true(server.feeds.iter().all(feed => feed.closes() == 1))
}

///|
test "an empty event ID removes the caller header while preserving Accept" {
  let d = @driver.Driver::new()
  let server = SseServer::new(d, [
    Events([Chunk(b"id: next\ndata: a\n\n"), End]),
    Events([Chunk(b"id:\n\n"), End]),
    Answer(204, []),
  ])
  let client = server.client()
  let received = []
  let end = d.run(() => {
    client.sse_reconnecting(
      @mttp_core.Request::get("/events")
      .header("last-event-id", "initial")
      .header("accept", "text/event-stream; custom=yes"),
      event => received.push(event.data),
      policy=sse_policy(),
    )
  })
  assert_true(end is NoContent)
  assert_eq(received, ["a"])
  assert_eq(server.seen, [
    (0L, Some("initial"), Some("text/event-stream; custom=yes")),
    (100L, Some("next"), Some("text/event-stream; custom=yes")),
    (300L, None, Some("text/event-stream; custom=yes")),
  ])
  assert_true(server.feeds.iter().all(feed => feed.closes() == 1))
}

///|
test "a reconnecting stream propagates Client configuration errors before sending" {
  let d = @driver.Driver::new()
  let sends = Ref(0)
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      sends.val += 1
      @mttp_core.Response::new(204)
    }),
    @sim.SimClock::new(d),
    total_ms=1000,
  )
  try
    d.run(() => {
      client.sse_reconnecting(
        @mttp_core.Request::get("https://api.example/events"),
        _ => fail("no event expected"),
        policy=sse_policy(),
      )
    })
  catch {
    @client.InvalidRequest(message="a total deadline requires a Timer") => ()
    error => raise error
  } noraise {
    _ => fail("expected Client configuration error")
  }
  assert_eq(sends.val, 0)
  assert_eq(d.now(), 0L)
}

///|
test "event stream statuses give up after max_attempts and honour Retry-After" {
  let d = @driver.Driver::new()
  let server = SseServer::new(d, [
    Answer(503, [("retry-after", "1")]),
    Answer(429, []),
    Answer(500, []),
  ])
  let client = server.client()
  let end = d.run(() => {
    client.sse_reconnecting(
      @mttp_core.Request::get("/events"),
      _ => fail("no event expected"),
      policy=sse_policy(max_attempts=2),
    )
  })
  match end {
    GaveUp(Status(@client.UnexpectedStatus(head, body~))) => {
      assert_eq(head.status, 500)
      assert_eq(body, b"why")
    }
    other => fail("unexpected end: \{Repr(other)}")
  }
  // Retry-After: 1 is the first wait; the second backs off from 100 ms.
  assert_eq(server.seen.map(seen => seen.0), [0L, 1000L, 1200L])
}

///|
test "a connection that lived reset_after_ms restarts the reconnect count" {
  let d = @driver.Driver::new()
  let server = SseServer::new(d, [
    Events([End]),
    Events([Wait(5000), End]),
    Events([End]),
  ])
  let client = server.client()
  let end = d.run(() => {
    client.sse_reconnecting(@mttp_core.Request::get("/events"), _ => (), policy={
      ..sse_policy(max_attempts=1),
      reset_after_ms: 5000,
    })
  })
  assert_true(end is GaveUp(Ended))
  // Without the reset, the second connection's end would give up.
  assert_eq(server.seen.map(seen => seen.0), [0L, 100L, 5200L])
}

///|
test "event streams stop on rejected statuses and content types" {
  let cases : Array[(SseStep, Int32, String)] = [
    (Answer(404, []), 404, "UnexpectedStatus"),
    (Answer(304, []), 304, "UnexpectedStatus"),
    (Answer(201, []), 201, "UnexpectedStatus"),
    (Answer(200, [("content-type", "text/html")]), 200, "Deserialization"),
    (Answer(200, []), 200, "Deserialization"),
  ]
  for case in cases {
    let (step, status, kind) = case
    let d = @driver.Driver::new()
    let server = SseServer::new(d, [step])
    let client = server.client()
    let end = d.run(() => {
      client.sse_reconnecting(
        @mttp_core.Request::get("/events"),
        _ => fail("no event expected"),
        policy=sse_policy(),
      )
    })
    match end {
      Rejected(failure) => {
        assert_eq(failure.head().status, status)
        let actual = match failure {
          UnexpectedStatus(_, ..) => "UnexpectedStatus"
          Deserialization(_, ..) => "Deserialization"
          @client.ResponseFailure::.. => "other"
        }
        assert_eq(actual, kind)
      }
      other => fail("unexpected end: \{Repr(other)}")
    }
    assert_eq(server.seen.length(), 1)
  }
}

///|
test "the stop predicate, a callback error and an oversized event end without reconnecting" {
  let d = @driver.Driver::new()
  let server = SseServer::new(d, [
    Events([Chunk(b"data: a\n\ndata: [DONE]\n\ndata: late\n\n")]),
  ])
  let received = []
  let client = server.client()
  let end = d.run(() => {
    client.sse_reconnecting(
      @mttp_core.Request::get("/events"),
      event => received.push(event.data),
      stop=event => event.data == "[DONE]",
    )
  })
  match end {
    Stopped(event) => assert_eq(event.data, "[DONE]")
    other => fail("unexpected end: \{Repr(other)}")
  }
  assert_eq(received, ["a"])
  assert_eq(server.feeds[0].closes(), 1)
  // A transport failure raised by the callback is not taken for the
  // stream's: it is raised as it is.
  let d = @driver.Driver::new()
  let server = SseServer::new(d, [Events([Chunk(b"data: a\n\n")])])
  let client = server.client()
  let raised = try {
    ignore(
      d.run(() => {
        client.sse_reconnecting(@mttp_core.Request::get("/events"), _ => {
          raise reset_error()
        })
      }),
    )
    None
  } catch {
    @mttp_core.TransportError(detail~, ..) => Some(detail)
    error => raise error
  }
  assert_eq(raised, Some("reset"))
  assert_eq(server.seen.length(), 1)
  assert_eq(server.feeds[0].closes(), 1)
  // An event over max_event_bytes would arrive again on reconnect.
  let d = @driver.Driver::new()
  let server = SseServer::new(d, [Events([Chunk(b"data: 0123456789\n\n")])])
  let client = server.client()
  let raised = try {
    ignore(
      d.run(() => {
        client.sse_reconnecting(
          @mttp_core.Request::get("/events"),
          _ => (),
          max_event_bytes=8,
        )
      }),
    )
    None
  } catch {
    @mttp_core.TransportError(kind~, ..) => Some(kind)
    error => raise error
  }
  assert_eq(raised, Some(TooLarge(limit=8)))
  assert_eq(server.seen.length(), 1)
}

///|
test "cancellation during a reconnect wait sends nothing more" {
  let d = @driver.Driver::new()
  let server = SseServer::new(d, [Events([End]), Events([End])])
  let client = server.client()
  d.run(() => {
    let task = d.spawn(() => {
      ignore(
        client.sse_reconnecting(@mttp_core.Request::get("/events"), _ => (), policy={
          ..sse_policy(),
          backoff: { base_ms: 5000, max_ms: 5000, jitter: NoJitter, },
        }),
      )
    })
    d.sleep(1000)
    task.cancel()
    assert_false(task.wait())
  })
  assert_eq(server.seen.length(), 1)
  assert_eq(d.now(), 1000L)
}

///|
test "closing the Client during a reconnect wait returns the last end" {
  let d = @driver.Driver::new()
  let server = SseServer::new(d, [Events([Fail(reset_error())]), Events([End])])
  let client = server.client()
  let end = d.run(() => {
    let result = Ref(None)
    let task = d.spawn(() => {
      result.val = Some(
        client.sse_reconnecting(
          @mttp_core.Request::get("/events"),
          _ => (),
          policy=sse_policy(),
        ),
      )
    })
    d.sleep(50)
    client.close()
    assert_true(task.wait())
    result.val
  })
  match end {
    Some(GaveUp(Failed(@mttp_core.TransportError(kind=Network, ..)))) => ()
    other => fail("unexpected end: \{Repr(other)}")
  }
  assert_eq(server.seen.length(), 1)
}

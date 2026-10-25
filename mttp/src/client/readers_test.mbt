///|
priv struct EmptyBackend {}

///|
test "default response body limit is 64 MiB" {
  assert_eq(@client.RequestOptions::default().max_body_bytes, 64 * 1024 * 1024)
}

///|
impl @client.Backend for EmptyBackend with fn send(_, _, _) {
  @model.Response::new(200)
}

///|
priv struct InvalidTimer {}

///|
priv struct CompletedAtDeadlineTimer {}

///|
impl @clock.Timer for CompletedAtDeadlineTimer with fn within(_, _, callback) {
  callback()
  false
}

///|
test "completed timer callbacks transfer and close streams even at expiry" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, [b"data"])
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.SimClock::new(d),
    timer=CompletedAtDeadlineTimer::{ },
  )
  let reply = d.run(() => {
    client.send(
      @client.request(@model.Request::get("/"))
      .timeout_ms(10)
      .response(@client.as_stream((_, stream) => stream.read_some())),
    )
  })
  assert_eq(reply.body, Some(b"data"))
  assert_eq(source.closes(), 1)
}

///|
impl @clock.Timer for InvalidTimer with fn within(_, _, _) {
  true
}

///|
test "byte readers enforce bounds for all body variants" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, [b"ab"])
  assert_eq(
    d.run(() => @client.read_body(Stream(@model.StreamBody::new(source)), 2)),
    b"ab",
  )
  assert_eq(source.closes(), 1)
  assert_eq(d.run(() => @client.read_body(Empty, 0)), b"")
  for
    body in [
      @model.Body::Empty,
      Bytes(b""),
      Stream(@model.StreamBody::new(@feed.Feed::bytes(d, []))),
    ] {
    let rejected = try {
      let _ = d.run(() => @client.read_body(body, -1))
      false
    } catch {
      @model.TransportError(kind=Invalid, ..) => true
      error => raise error
    }
    assert_true(rejected)
  }
  let rejected = try {
    let _ = d.run(() => @client.read_body(Bytes(b"ab"), 1))
    false
  } catch {
    @model.TransportError(kind=TooLarge(limit=1), ..) => true
    error => raise error
  }
  assert_true(rejected)
}

///|
test "streaming readers adapt memory bodies with sticky EOF" {
  let clock = @fake.FakeClock::new()
  for body in [@model.Body::Empty, Bytes(b""), Bytes(b"data")] {
    let client = @client.Client::new(
      @client.from_handler(_ => @model.Response::new(200, body~)),
      clock,
    )
    let reader = @client.as_stream((_, stream) => {
      let first = stream.read_some()
      assert_eq(stream.read_some(), None)
      stream.close()
      assert_eq(stream.read_some(), None)
      first
    })
    let result = @driver.run_sync(() => {
      client.send(@client.request(@model.Request::get("/")).response(reader))
    })
    assert_eq(
      result.body,
      if body == Bytes(b"data") {
        Some(b"data")
      } else {
        None
      },
    )
  }
}

///|
test "ignore body closes without consuming it and quick request accepts errors" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, [b"unread"])
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.SimClock::new(d),
  )
  let _ = d.run(() => {
    client.send(
      @client.request(@model.Request::get("/")).response(@client.ignore_body()),
    )
  })
  assert_eq(source.reads(), 0)
  assert_eq(source.closes(), 1)
  let client = @client.Client::new(
    @client.from_handler(_ => @model.Response::new(404, body=Bytes(b"missing"))),
    @fake.FakeClock::new(),
  )
  assert_eq(
    @driver.run_sync(() => {
      client.send(@client.quick_request(@model.Request::get("/")))
    }).body,
    "missing",
  )
}

///|
test "error bodies include empty and buffered responses" {
  for body in [@model.Body::Empty, Bytes(b"bad")] {
    let client = @client.Client::new(
      @client.from_handler(_ => @model.Response::new(400, body~)),
      @fake.FakeClock::new(),
    )
    let rejected = try {
      let _ = @driver.run_sync(() => {
        client.send(@client.request(@model.Request::get("/")))
      })
      false
    } catch {
      @client.UnexpectedStatus(_, body=excerpt) => {
        assert_eq(Some(excerpt), body.as_bytes())
        true
      }
      error => raise error
    }
    assert_true(rejected)
  }
  let client = @client.Client::new(
    @client.from_handler(_ => @model.Response::new(200, body=Bytes(b"invalid"))),
    @fake.FakeClock::new(),
  )
  let rejected = try {
    let _ = @driver.run_sync(() => {
      client.send(
        @client.request(@model.Request::get("/")).response(
          @client.as_json_value(),
        ),
      )
    })
    false
  } catch {
    @client.Deserialization(_, ..) => true
    error => raise error
  }
  assert_true(rejected)
}

///|
test "SSE reader consumes EOF and discards an unfinished final event" {
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @model.Response::new(200, body=Bytes(b"data: one\n\ndata: unfinished"))
    }),
    @fake.FakeClock::new(),
  )
  let events = []
  let _ = @driver.run_sync(() => {
    client.send(
      @client.request(@model.Request::get("/")).response(
        @client.as_sse(event => events.push(event.data)),
      ),
    )
  })
  assert_eq(events, ["one"])
}

///|
test "fallback handles completion errors and a broken timer contract" {
  let d = @driver.Driver::new()
  let clock = @fake.SimClock::new(d)
  for status in [200, 500] {
    let client = @client.Client::new(
      @client.from_handler(_ => @model.Response::new(status)),
      clock,
      timer=@fake.SimTimer::new(d),
    )
    let result = try {
      let _ = d.run(() => {
        client.send(@client.request(@model.Request::get("/")).timeout_ms(10))
      })
      true
    } catch {
      @client.UnexpectedStatus(_, ..) => false
      error => raise error
    }
    assert_eq(result, status == 200)
  }
  let client = @client.Client::new(EmptyBackend::{ }, clock, timer=InvalidTimer::{
  })
  let rejected = try {
    let _ = d.run(() => {
      client.send(@client.request(@model.Request::get("/")).timeout_ms(1))
    })
    false
  } catch {
    @model.TransportError(kind=Protocol, ..) => true
    error => raise error
  }
  assert_true(rejected)
  client.close()
}

///|
test "late returned response is closed and option attributes stay independent" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, [b"late"])
  let options_seen = []
  let client = @client.Client::new(
    @client.from_fn((_, options) => {
      options_seen.push(options)
      d.sleep(10)
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.SimClock::new(d),
  )
  let request = @client.request(@model.Request::get("/"))
    .timeout_ms(5)
    .read_idle_ms(7)
    .attribute(@client.rate_limit_bucket, "bucket")
    .attribute(@client.global_exempt, true)
    .attribute(@client.operation_id, "operation")
  let rejected = try {
    let _ = d.run(() => client.send(request))
    false
  } catch {
    @model.TransportError(kind=Timeout(..), ..) => true
    error => raise error
  }
  assert_true(rejected)
  assert_eq(source.closes(), 1)
  assert_eq(options_seen[0].read_idle_ms, Some(7))
  assert_eq(
    request.raw().attributes.get(@client.rate_limit_bucket),
    Some("bucket"),
  )
}

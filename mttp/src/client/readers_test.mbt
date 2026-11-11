///|
priv struct EmptyBackend {}

///|
test "the default body limit is 64 MiB and is sent as the wire cap" {
  let seen = []
  let client = @client.Client::new(
    @client.from_fn((_, options) => {
      seen.push(options)
      @mttp.Response::new(200)
    }),
    @sim.FakeClock::new(),
  )
  ignore(@driver.run_sync(() => client.send(@client.get("/"))))
  assert_eq(seen, [@mttp.SendOptions::default()])
  assert_eq(seen[0].body, Exchange(max_bytes=64 * 1024 * 1024))
}

///|
impl @mttp.Backend for EmptyBackend with fn send(_, _, _) {
  @mttp.Response::new(200)
}

///|
priv struct InvalidTimer {}

///|
priv struct CompletedAtDeadlineTimer {}

///|
impl @rt.Timer for CompletedAtDeadlineTimer with fn within(_, _, callback) {
  callback()
  false
}

///|
test "completed timer callbacks transfer and close streams even at expiry" {
  let d = @driver.Driver::new()
  let source = @sim.Feed::bytes(d, [b"data"])
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @mttp.Response::new(200, body=Stream(@mttp.StreamBody::new(source)))
    }),
    @sim.SimClock::new(d),
    timer=CompletedAtDeadlineTimer::{ },
  )
  let reply = d.run(() => {
    client.send(
      @client.request(@mttp.Request::get("/"))
      .timeout_ms(10)
      .response(@client.as_stream((_, stream) => stream.read_some())),
    )
  })
  assert_eq(reply.body, Ok(Some(b"data")))
  assert_eq(source.closes(), 1)
}

///|
impl @rt.Timer for InvalidTimer with fn within(_, _, _) {
  true
}

///|
test "streaming readers adapt memory bodies with sticky EOF" {
  let clock = @sim.FakeClock::new()
  for body in [@mttp.Body::Empty, Bytes(b""), Bytes(b"data")] {
    let client = @client.Client::new(
      @client.from_handler(_ => @mttp.Response::new(200, body~)),
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
      client.send(@client.request(@mttp.Request::get("/")).response(reader))
    })
    assert_eq(
      result.body,
      Ok(if body == Bytes(b"data") { Some(b"data") } else { None }),
    )
  }
}

///|
test "ignore body closes without consuming it and any_status accepts errors" {
  let d = @driver.Driver::new()
  let source = @sim.Feed::bytes(d, [b"unread"])
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @mttp.Response::new(200, body=Stream(@mttp.StreamBody::new(source)))
    }),
    @sim.SimClock::new(d),
  )
  let _ = d.run(() => {
    client.send(
      @client.request(@mttp.Request::get("/")).response(@client.ignore_body()),
    )
  })
  assert_eq(source.reads(), 0)
  assert_eq(source.closes(), 1)
  let client = @client.Client::new(
    @client.from_handler(_ => @mttp.Response::new(404, body=Bytes(b"missing"))),
    @sim.FakeClock::new(),
  )
  assert_eq(
    @driver.run_sync(() => {
      client.send(
        @client.request(@mttp.Request::get("/")).response(
          @client.as_string().any_status(),
        ),
      )
    }).body,
    Ok("missing"),
  )
}

///|
test "error bodies include empty and buffered responses" {
  for body in [@mttp.Body::Empty, Bytes(b"bad")] {
    let client = @client.Client::new(
      @client.from_handler(_ => @mttp.Response::new(400, body~)),
      @sim.FakeClock::new(),
    )
    let rejected = match
      @driver.run_sync(() => client.send(@client.get("/"))).body {
      Err(@client.UnexpectedStatus(_, body=excerpt)) => {
        assert_eq(Some(excerpt), body.as_bytes())
        true
      }
      _ => false
    }
    assert_true(rejected)
  }
  let client = @client.Client::new(
    @client.from_handler(_ => @mttp.Response::new(200, body=Bytes(b"invalid"))),
    @sim.FakeClock::new(),
  )
  let rejected = @driver.run_sync(() => {
      client.send(@client.get("/").response(@client.as_json_value()))
    }).body
    is Err(@client.Deserialization(_, ..))
  assert_true(rejected)
}

///|
test "SSE reader consumes EOF and discards an unfinished final event" {
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @mttp.Response::new(200, body=Bytes(b"data: one\n\ndata: unfinished"))
    }),
    @sim.FakeClock::new(),
  )
  let events = []
  let _ = @driver.run_sync(() => {
    client.send(
      @client.request(@mttp.Request::get("/")).response(
        @client.as_sse(event => events.push(event.data)),
      ),
    )
  })
  assert_eq(events, ["one"])
}

///|
test "fallback handles completion errors and a broken timer contract" {
  let d = @driver.Driver::new()
  let clock = @sim.SimClock::new(d)
  for status in [200, 500] {
    let client = @client.Client::new(
      @client.from_handler(_ => @mttp.Response::new(status)),
      clock,
      timer=@sim.SimTimer::new(d),
    )
    let result = d.run(() => client.send(@client.get("/").timeout_ms(10))).body
      is Ok(_)
    assert_eq(result, status == 200)
  }
  let client = @client.Client::new(EmptyBackend::{ }, clock, timer=InvalidTimer::{
  })
  let rejected = try {
    let _ = d.run(() => {
      client.send(@client.request(@mttp.Request::get("/")).timeout_ms(1))
    })
    false
  } catch {
    @mttp.TransportError(kind=Protocol, ..) => true
    error => raise error
  }
  assert_true(rejected)
  client.close()
  // The total deadline refuses the same broken Timer, before any send.
  let client = @client.Client::new(
    EmptyBackend::{ },
    clock,
    timer=InvalidTimer::{ },
    total_ms=10,
  )
  let rejected = try {
    let _ = d.run(() => client.send(@client.get("/")))
    false
  } catch {
    @client.InvalidRequest(..) => true
    error => raise error
  }
  assert_true(rejected)
}

///|
test "reject refuses even a successful status, with a bounded excerpt" {
  let client = @client.Client::new(
    @client.from_handler(_ => @mttp.Response::new(200, body=Bytes(b"html"))),
    @sim.FakeClock::new(),
  )
  let plan : @client.ResponseAs[Result[String, @client.ResponseFailure]] = @client.from_head(head => {
      if head.headers.get("content-type") is Some("application/json") {
        @client.as_string()
      } else {
        @client.ResponsePlan::reject()
      }
    },
  )
  let reply = @driver.run_sync(() => {
    client.send(@client.request(@mttp.Request::get("/")).response(plan))
  })
  guard reply.body is Err(UnexpectedStatus(head, body~)) else {
    fail("expected a rejection")
  }
  assert_eq(head.status, 200)
  assert_eq(body, b"html")
}

///|
test "late returned response is closed and option attributes stay independent" {
  let d = @driver.Driver::new()
  let source = @sim.Feed::bytes(d, [b"late"])
  let options_seen = []
  let client = @client.Client::new(
    @client.from_fn((_, options) => {
      options_seen.push(options)
      d.sleep(10)
      @mttp.Response::new(200, body=Stream(@mttp.StreamBody::new(source)))
    }),
    @sim.SimClock::new(d),
  )
  let request = @client.request(@mttp.Request::get("/"))
    .response(@client.as_stream((_, stream) => stream.read_some()))
    .timeout_ms(5)
    .read_idle_ms(7)
    .attribute(@client.rate_limit_bucket, "bucket")
    .attribute(@client.global_exempt, true)
    .attribute(@client.operation_id, "operation")
  let rejected = try {
    let _ = d.run(() => client.send(request))
    false
  } catch {
    @mttp.TransportError(kind=Timeout(..), ..) => true
    error => raise error
  }
  assert_true(rejected)
  assert_eq(source.closes(), 1)
  assert_eq(options_seen[0], {
    timeout_ms: Some(5),
    body: Stream(idle_ms=Some(7)),
  })
  assert_eq(
    request.raw().attributes.get(@client.rate_limit_bucket),
    Some("bucket"),
  )
}

///|
test "fluent request bodies and authorization reach the shared executor" {
  @driver.run_sync(() => {
    let wire = Ref(@model.Request::get("/unset"))
    let client = @client.Client::new(
      @client.from_fn((request, _) => {
        wire.val = request
        @model.Response::new(200, body=request.body)
      }),
      @fake.FakeClock::new(),
    )
    let request = @client.post("/items")
      .header("x-test", "yes")
      .bearer("token")
      .body_fn(() => abort("superseded factory must not run"))
      .body_bytes(b"bytes")
      .response(@client.as_bytes())
    assert_eq(request.send(client).body, Ok(b"bytes"))
    assert_eq(wire.val.meth, @model.Post)
    assert_eq(wire.val.headers.get("authorization"), Some("Bearer token"))
    assert_eq(wire.val.headers.get("x-test"), Some("yes"))
    assert_eq(request.body_json({ "n": 1 }).send(client).body, Ok(b"{\"n\":1}"))
  })
}

///|
test "rejected readers retain bounded values without invoking consumers" {
  @driver.run_sync(() => {
    let response = Ref(@model.Response::new(503, body=Bytes(b"busy")))
    let client = @client.Client::new(
      @client.from_fn((_, _) => response.val),
      @fake.FakeClock::new(),
    )
    let request = @client.get("/")
    let integer : @client.ResponseAs[Result[Int32, @client.ResponseFailure]] = @client.as_json()
    assert_true(
      request.response(@client.as_json_value()).send(client).body
      is Err(@client.UnexpectedStatus(_, ..)),
    )
    assert_true(
      request.response(integer).send(client).body
      is Err(@client.UnexpectedStatus(_, ..)),
    )
    assert_true(
      request.response(@client.ignore_body()).send(client).body
      is Err(@client.UnexpectedStatus(_, ..)),
    )
    assert_true(
      request
      .response(
        @client.as_stream((_, _) => {
          fail("rejected consumer ran")
          ()
        }),
      )
      .send(client).body
      is Err(@client.UnexpectedStatus(_, ..)),
    )
    let pair = request
      .response(@client.as_both(@client.as_bytes(), @client.as_string()))
      .send(client).body
    assert_true(pair is (Err(_), Err(_)))
    response.val = @model.Response::new(
      200,
      body=Bytes(Bytes::make(2 * 1048576, b'x')),
    )
    guard request.response(@client.as_json_value()).send(client).body
      is Err(@client.Deserialization(_, body~, ..)) else {
      fail("invalid JSON accepted")
    }
    assert_eq(body.length(), 1048576)
    assert_true(
      request.response(integer).send(client).body
      is Err(@client.Deserialization(_, ..)),
    )
  })
}

///|
test "typed retry can inspect an HTTP 200 value without changing HTTP observations" {
  let d = @driver.Driver::new()
  let calls = Ref(0)
  let observations = []
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      @model.Response::new(
        200,
        body=Bytes(if calls.val == 1 { b"retry" } else { b"done" }),
      )
    }),
    @fake.SimClock::new(d),
    retry=@client.RetryPolicy::conservative(),
    observer=attempt => {
      observations.push((attempt.status, attempt.error is None))
    },
  )
  let request = @client.get("/").response(
    @client.as_string().map_ok(value => value == "done"),
  )
  let reply = d.run(() => {
    request.send(client, decide_retry=(attempt, context) => {
      match attempt {
        Buffered(reply) if reply.body is Ok(false) => Wait(1)
        _ => context.default_decision
      }
    })
  })
  assert_eq(reply.body, Ok(true))
  assert_eq(observations, [(200, true), (200, true)])
}

///|
test "custom retry cannot exceed the configured count even on success" {
  let d = @driver.Driver::new()
  let calls = Ref(0)
  let decisions = []
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      @model.Response::new(200, body=Bytes(b"last"))
    }),
    @fake.SimClock::new(d),
    retry=@client.RetryPolicy::none().with_max_retries(2),
    observer=attempt => decisions.push(attempt.decision),
  )
  let reply = d.run(() => {
    @client.get("/").send(client, decide_retry=(_, _) => Wait(0))
  })
  assert_eq(reply.body, Ok("last"))
  assert_eq(calls.val, 3)
  assert_eq(decisions, [Some(Wait(0)), Some(Wait(0)), Some(Stop(Exhausted))])
}

///|
suberror MappingMarker {
  MappingMarker(Int32)
}

///|
test "unknown decoder errors preserve identity and are never offered for retry" {
  let clock = @fake.FakeClock::new()
  let decisions = Ref(0)
  let releases = Ref(0)
  let client = @client.Client::new(
    @client.from_fn((_, _) => @model.Response::new(200)),
    clock,
    retry=@client.RetryPolicy::conservative(),
    observer=_ => releases.val += 1,
  )
  let reader : @client.ResponseAs[Int32] = @client.as_string().map(_ => {
    raise MappingMarker(9)
  })
  try {
    let _ = @driver.run_sync(() => {
      @client.get("/")
      .response(reader)
      .send(client, decide_retry=(_, _) => {
        decisions.val += 1
        Wait(0)
      })
    })
    fail("mapping exception lost")
  } catch {
    MappingMarker(9) => ()
    error => raise error
  }
  assert_eq((decisions.val, releases.val), (0, 1))
}

///|
test "configured total deadline requires Timer before admission or body creation" {
  let calls = Ref(0)
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      @model.Response::new(200)
    }),
    @fake.FakeClock::new(),
    total_ms=100,
  )
  try {
    let _ = @driver.run_sync(() => {
      @client.get("/")
      .body_fn(() => {
        calls.val += 1
        b""
      })
      .send(client)
    })
    fail("accepted total without Timer")
  } catch {
    @client.InvalidRequest(message="a total deadline requires a Timer") => ()
    error => raise error
  }
  assert_eq(calls.val, 0)
}

///|
test "head selection retains a buffered rejection before stream handoff" {
  let d = @driver.Driver::new()
  let calls = Ref(0)
  let consumed = Ref(0)
  let checks = []
  let source = @feed.Feed::bytes(d, [b"data"])
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      if calls.val == 1 {
        @model.Response::new(503, body=Bytes(b"busy"))
      } else {
        @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
      }
    }),
    @fake.SimClock::new(d),
    retry=@client.RetryPolicy::conservative(),
  )
  let reader = @client.from_head(head => {
    if head.status == 503 {
      @client.as_string().map_ok(_ => ()).as_streaming()
    } else {
      @client.as_stream((_, stream) => {
        consumed.val += 1
        assert_eq(stream.read_some(), Some(b"data"))
      })
    }
  })
  let _ = d.run(() => {
    @client.get("/")
    .response(reader)
    .send(client, decide_retry=(attempt, context) => {
      if context.attempt == 0 {
        checks.push(
          attempt
          is Buffered(
            { body: Err(@client.UnexpectedStatus({ status: 503, .. }, ..)), .. }
          ),
        )
      } else {
        checks.push(
          attempt is StreamReady({ status: 200, .. }) && consumed.val == 0,
        )
      }
      context.default_decision
    })
  })
  assert_eq((calls.val, consumed.val, source.closes()), (2, 1, 1))
  assert_eq(checks, [true, true])
}

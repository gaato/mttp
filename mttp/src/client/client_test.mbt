///|
test "backend wrappers validate and close once" {
  let mut calls = 0
  let mut closes = 0
  let backend = @client.from_fn(
    (_, _) => {
      calls += 1
      @model.Response::new(204)
    },
    on_close=() => closes += 1,
  )
  @driver.run_sync(() => {
    assert_eq(
      backend.send(@model.Request::get("/"), @client.RequestOptions::default()).status,
      204,
    )
    let refused = try {
      let _ = backend.send(
        @model.Request::get("/bad path"),
        @client.RequestOptions::default(),
      )
      false
    } catch {
      _ => true
    }
    assert_true(refused)
  })
  backend.close()
  backend.close()
  assert_eq(closes, 1)
  let refused = try {
    @driver.run_sync(() => {
      let _ = backend.send(
        @model.Request::get("/"),
        @client.RequestOptions::default(),
      )
    })
    false
  } catch {
    @model.TransportError(kind=Closed, ..) => true
    _ => false
  }
  assert_true(refused)
  assert_eq(calls, 1)
}

///|
test "client merges defaults and per-field overrides" {
  let d = @driver.Driver::new()
  let clock = @fake.SimClock::new(d)
  let seen = []
  let backend = @client.from_fn((request, options) => {
    seen.push((request, options))
    @model.Response::new(200, body=Bytes(b"ok"))
  })
  let client = @client.Client::new(
    backend,
    clock,
    base_url="https://h/v1",
    headers=@model.Headers::of([("accept", "default"), ("x", "1"), ("x", "2")]),
    options={
      ..@client.RequestOptions::default(),
      read_idle_ms: Some(99),
      max_body_bytes: 20,
    },
  )
  let key : @model.AttributeKey[Int32] = @model.AttributeKey::new("k")
  let request = @client.ClientRequest::new(
      @model.Request::post("/items").header("accept", "own"),
      @client.as_bytes(),
    )
    .timeout_ms(30)
    .max_body_bytes(10)
    .attribute(key, 4)
    .body_fn(() => b"built")
    .response(@client.as_string())
  let reply = d.run(() => client.send(request))
  assert_eq(reply.body, Ok("ok"))
  assert_eq(reply.request.url, "https://h/v1/items")
  assert_eq(seen[0].0.headers.get("accept"), Some("own"))
  assert_eq(seen[0].0.headers.get_all("x"), ["1", "2"])
  assert_eq(seen[0].0.attributes.get(key), Some(4))
  assert_eq(seen[0].0.body.as_bytes(), Some(b"built"))
  assert_eq(seen[0].1.timeout_ms, Some(30))
  assert_eq(seen[0].1.read_idle_ms, Some(99))
  assert_eq(seen[0].1.max_body_bytes, 10)
  assert_true(seen[0].1.body_deadline)
  assert_eq(request.raw().url, "/items")
  client.close()
}

///|
test "head selection runs once and any-status permits rejection statuses" {
  let d = @driver.Driver::new()
  let mut choices = 0
  let heads = []
  let client = @client.Client::new(
    @client.from_handler(_ => @model.Response::new(404, body=Bytes(b"missing"))),
    @fake.SimClock::new(d),
  )
  let reader = @client.from_head(head => {
    choices += 1
    heads.push(head.status)
    @client.as_string().any_status()
  }).map_with_head((body, head) => "\{head.status}:\{body.unwrap()}")
  let result = d.run(() => {
    client.send(@client.request(@model.Request::get("/")).response(reader))
  })
  assert_eq(result.body, "404:missing")
  assert_eq(choices, 1)
  assert_eq(heads, [404])
}

///|
test "unexpected statuses retain at most one MiB and close streams" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, [
    Bytes::make(@client.max_error_body + 10, b'x'),
  ])
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @model.Response::new(503, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.SimClock::new(d),
  )
  let failed = match d.run(() => client.send(@client.get("/"))).body {
    Err(@client.UnexpectedStatus(head, body~) as error) => {
      assert_eq(head.status, 503)
      assert_eq(@client.status_of(error), Some(503))
      assert_eq(body.length(), @client.max_error_body)
      true
    }
    _ => false
  }
  assert_true(failed)
  assert_eq(source.closes(), 1)
}

///|
test "JSON readers classify syntax UTF-8 and type failures" {
  let clock = @fake.FakeClock::new()
  for bytes in [b"not json", b"\xff", b"\"wrong type\""] {
    let client = @client.Client::new(
      @client.from_handler(_ => @model.Response::new(200, body=Bytes(bytes))),
      clock,
    )
    let request : @client.ClientRequest[Result[Int32, @client.ResponseFailure]] = @client.request(
      @model.Request::get("/"),
    ).response(@client.as_json())
    let failed = match @driver.run_sync(() => client.send(request)).body {
      Err(@client.Deserialization(head, body~, ..) as error) => {
        assert_eq(head.status, 200)
        assert_eq(body, bytes)
        assert_eq(@client.status_of(error), Some(200))
        true
      }
      _ => false
    }
    assert_true(failed)
  }
  let client = @client.Client::new(
    @client.from_handler(_ => @model.Response::new(200, body=Bytes(b"42"))),
    clock,
  )
  assert_eq(
    @driver.run_sync(() => {
      client.send(
        @client.request(@model.Request::get("/")).response(
          @client.as_json_value(),
        ),
      )
    }).body,
    Ok(Json::number(42)),
  )
  let request : @client.ClientRequest[Result[Int32, @client.ResponseFailure]] = @client.request(
    @model.Request::get("/"),
  ).response(@client.as_json())
  assert_eq(@driver.run_sync(() => client.send(request)).body, Ok(42))
}

///|
test "stream callbacks close on error and accepted streams disable body deadline" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, [b"data"])
  let deadlines = []
  let client = @client.Client::new(
    @client.from_fn((_, options) => {
      deadlines.push(options.body_deadline)
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.SimClock::new(d),
  )
  let request : @client.StreamRequest[Result[Unit, @client.ResponseFailure]] = @client.request(
    @model.Request::get("/"),
  ).response(
    @client.as_stream((_, stream) => {
      assert_eq(stream.read_some(), Some(b"data"))
      raise @client.InvalidRequest(message="callback failure")
    }),
  )
  let failed = try {
    let _ = d.run(() => client.send(request))
    false
  } catch {
    @client.InvalidRequest(message="callback failure") => true
    other => raise other
  }
  assert_true(failed)
  assert_eq(source.closes(), 1)
  assert_eq(deadlines, [false])
}

///|
test "SSE stops before a protocol sentinel and closes" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, [
    b"data: one\n\ndata: [DONE]\n\ndata: never\n\n",
  ])
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.SimClock::new(d),
  )
  let events = []
  let request = @client.request(@model.Request::get("/")).response(
    @client.as_sse(event => events.push(event.data), stop=event => {
      event.data == "[DONE]"
    }),
  )
  let _ = d.run(() => client.send(request))
  assert_eq(events, ["one"])
  assert_eq(source.closes(), 1)
}

///|
test "fallback timer bounds slow backends and nonpositive attempts never send" {
  let d = @driver.Driver::new()
  let mut sent = 0
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      sent += 1
      d.sleep(20)
      @model.Response::new(200)
    }),
    @fake.SimClock::new(d),
    timer=@fake.SimTimer::new(d),
  )
  for limit in [0, -1, 5] {
    let failed = try {
      let _ = d.run(() => {
        client.send(@client.request(@model.Request::get("/")).timeout_ms(limit))
      })
      false
    } catch {
      @model.TransportError(kind=Timeout(..), ..) => true
      _ => false
    }
    assert_true(failed)
  }
  assert_eq(sent, 1)
  assert_eq(d.now(), 5)
}

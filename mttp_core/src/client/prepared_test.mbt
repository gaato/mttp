///|
test "prepared stream decodes before retry and consumes after observation through mapped head selection" {
  let events = []
  let calls = Ref(0)
  let client = @client.Client::new(
    @client.from_handler(_ => {
      calls.val += 1
      @mttp_core.Response::new(
        if calls.val == 1 {
          503
        } else {
          200
        },
        body=Bytes(b"value"),
      )
    }),
    @sim.FakeClock::new(),
    retry=@client.RetryPolicy::conservative(),
    observer=attempt => events.push("observe:\{attempt.status}"),
  )
  defer client.close()
  let reader = @client.ResponsePlan::prepared_stream(
    (head, bytes) => {
      events.push("decode:\{head.status}")
      assert_eq(bytes, b"value")
      if head.status == 503 {
        Err(-1)
      } else {
        Ok(7)
      }
    },
    value => {
      events.push("consume")
      value + 1
    },
  ).map_with_head((value, head) => value + head.status)
  let result = @driver.run_sync(() => {
    @client.get("/").response(@client.from_head(_ => reader)).send(client).body
  })
  assert_eq(result, 208)
  assert_eq(events, [
    "decode:503", "observe:503", "decode:200", "observe:200", "consume",
  ])
}

///|
test "prepared streams keep decoded limits and never retry callback exceptions" {
  let d = @driver.Driver::new()
  let calls = Ref(0)
  let source = @sim.Feed::bytes(d, [b"abcd"])
  let client = @client.Client::new(
    @client.from_handler(_ => {
      calls.val += 1
      @mttp_core.Response::new(
        200,
        body=Stream(@mttp_core.StreamBody::new(source)),
      )
    }),
    @sim.FakeClock::new(),
    retry=@client.RetryPolicy::conservative(),
  )
  defer client.close()
  let reader = @client.ResponsePlan::prepared_stream((_, bytes) => Ok(bytes), bytes => {
    bytes.length()
  })
  d.run(() => {
    try {
      ignore(@client.get("/").max_body_bytes(3).response(reader).send(client))
      fail("crossing body accepted")
    } catch {
      @mttp_core.TransportError(kind=TooLarge(limit=3), ..) => ()
      error => raise error
    }
  })
  assert_eq(source.closes(), 1)
  let original = Failure("consumer")
  let client = @client.Client::new(
    @client.from_handler(_ => {
      calls.val += 1
      @mttp_core.Response::new(200, body=Bytes(b"x"))
    }),
    @sim.FakeClock::new(),
    retry=@client.RetryPolicy::conservative(),
  )
  defer client.close()
  let reader = @client.ResponsePlan::prepared_stream((_, _) => Ok(()), _ => {
    raise original
    ()
  })
  let before = calls.val
  @driver.run_sync(() => {
    try {
      ignore(@client.get("/").response(reader).send(client))
      fail("consumer exception lost")
    } catch {
      Failure(_) as error => assert_true(physical_equal(error, original))
      error => raise error
    }
  })
  assert_eq(calls.val, before + 1)
}

///|
test "prepared decoding remains inside the attempt deadline" {
  let clock = @sim.FakeClock::new()
  let consumed = Ref(false)
  let reader = @client.ResponsePlan::prepared_stream(
    (_, _) => {
      clock.advance(11)
      Ok(())
    },
    _ => consumed.val = true,
  )
  let client = @client.Client::new(
    @client.from_handler(_ => @mttp_core.Response::new(200)),
    clock,
  )
  defer client.close()
  @driver.run_sync(() => {
    try {
      ignore(@client.get("/").timeout_ms(10).response(reader).send(client))
      fail("expired preparation reached callback")
    } catch {
      @mttp_core.TransportError(kind=Timeout(ms=10), ..) => ()
      error => raise error
    }
  })
  assert_false(consumed.val)
}

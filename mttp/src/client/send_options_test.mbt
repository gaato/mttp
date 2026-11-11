///|
fn recording(seen : Array[@mttp.SendOptions]) -> &@mttp.Backend {
  @client.from_fn((_, options) => {
    seen.push(options)
    @mttp.Response::new(200, body=Bytes(b"ok"))
  })
}

///|
test "the plan's mode chooses Exchange or Stream and overrides win field by field" {
  let seen = []
  let client = @client.Client::new(
    recording(seen),
    @sim.FakeClock::new(),
    timeout_ms=1000,
    max_body_bytes=100,
    read_idle_ms=50,
  )
  let get = @client.request(@mttp.Request::get("/"))
  let stream = @client.as_stream((_, s) => s.read_some())
  @driver.run_sync(() => {
    ignore(client.send(get))
    ignore(client.send(get.response(stream)))
    // A Streaming description that may select a buffered branch.
    ignore(client.send(get.response(@client.from_head(_ => stream))))
    // Every branch of a Buffered description is buffered.
    ignore(
      client.send(get.response(@client.from_head(_ => @client.as_bytes()))),
    )
    ignore(client.send(get.timeout_ms(7).max_body_bytes(3)))
    ignore(client.send(get.response(stream).read_idle_ms(9)))
  })
  assert_eq(seen, [
    { timeout_ms: Some(1000), body: Exchange(max_bytes=100), },
    { timeout_ms: Some(1000), body: Stream(idle_ms=Some(50)), },
    { timeout_ms: Some(1000), body: Stream(idle_ms=Some(50)), },
    { timeout_ms: Some(1000), body: Exchange(max_bytes=100), },
    { timeout_ms: Some(7), body: Exchange(max_bytes=3), },
    { timeout_ms: Some(1000), body: Stream(idle_ms=Some(9)), },
  ])
}

///|
test "a buffered branch selected from a Stream head keeps the attempt deadline" {
  let d = @driver.Driver::new()
  let source = @sim.Feed::new(d, [
    Wait(3),
    Chunk(b"a"),
    Wait(10),
    Chunk(b"b"),
    End,
  ])
  let observed = []
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      d.sleep(2)
      @mttp.Response::new(200, body=Stream(@mttp.StreamBody::new(source)))
    }),
    @sim.SimClock::new(d),
    timer=@sim.SimTimer::new(d),
    timeout_ms=8,
    observer=attempt => {
      observed.push((attempt.status, attempt.error is Some(_)))
    },
  )
  let plan = @client.from_head(_ => @client.as_bytes().as_streaming())
  let failure = try {
    ignore(
      d.run(() => {
        client.send(@client.request(@mttp.Request::get("/")).response(plan))
      }),
    )
    None
  } catch {
    @mttp.TransportError(kind~, ..) => Some(kind)
    error => raise error
  }
  // The head came at 2 ms; the read was cut at the attempt's 8 ms, not 2 + 8.
  assert_eq(failure, Some(Timeout(ms=8)))
  assert_eq(d.now(), 8L)
  assert_eq(observed, [(200, true)])
  assert_eq(source.closes(), 1)
}

///|
test "a buffered branch selected from a Stream head keeps the decoded byte limit" {
  let d = @driver.Driver::new()
  let cases : Array[(Bytes, Result[Bytes, @mttp.Kind])] = [
    (b"four", Ok(b"four")),
    (b"five!", Err(TooLarge(limit=4))),
  ]
  let timings = []
  for case in cases {
    let (bytes, expected) = case
    let source = @sim.Feed::bytes(d, @sim.byte_chunks(bytes))
    let client = @client.Client::new(
      @client.from_fn((_, options) => {
        timings.push(options.body)
        @mttp.Response::new(200, body=Stream(@mttp.StreamBody::new(source)))
      }),
      @sim.SimClock::new(d),
      max_body_bytes=4,
    )
    let plan = @client.from_head(head => {
      if head.status == 200 {
        @client.as_bytes().as_streaming()
      } else {
        @client.as_stream((_, _) => b"").map(_ => Ok(b""))
      }
    })
    let got = try {
      let reply = d.run(() => {
        client.send(@client.request(@mttp.Request::get("/")).response(plan))
      })
      Ok(reply.body.unwrap())
    } catch {
      @mttp.TransportError(kind~, phase=Body, ..) => Err(kind)
      error => raise error
    }
    assert_eq(got, expected)
    assert_eq(source.closes(), 1)
  }
}

///|
priv struct CountingLimiter {
  mut acquired : Int32
}

///|
impl @client.RateLimiter for CountingLimiter with fn acquire(
  self,
  bucket,
  global_exempt~,
) {
  let _ = global_exempt
  self.acquired += 1
  @client.Admission::new(bucket, sequence=self.acquired.to_int64())
}

///|
impl @client.RateLimiter for CountingLimiter with fn release(
  _,
  _,
  status~,
  headers~,
) {
  let _ = (status, headers)
}

///|
test "limits no attempt can honour fail before admission" {
  for
    case in [
      (-1, None, @mttp.Kind::Invalid),
      (10, Some(0), Invalid),
      (10, Some(-5), Invalid),
    ] {
    let (max_body_bytes, read_idle_ms, expected) = case
    let seen = []
    let limiter = CountingLimiter::{ acquired: 0, }
    let client = @client.Client::new(
      recording(seen),
      @sim.FakeClock::new(),
      max_body_bytes~,
      read_idle_ms?,
      limiter~,
    )
    let failure = try {
      ignore(@driver.run_sync(() => client.send(@client.get("/"))))
      None
    } catch {
      @mttp.TransportError(kind~, phase=Pool, ..) => Some(kind)
      error => raise error
    }
    assert_eq(failure, Some(expected))
    assert_eq(limiter.acquired, 0)
    assert_eq(seen.length(), 0)
  }
}

///|
test "redirect overrides of a plan travel as the redirect_limit attribute" {
  let seen = []
  let backend = @client.from_fn((request, options) => {
    seen.push((request.attributes.get(@client.redirect_limit), options))
    @mttp.Response::new(200)
  })
  let client = @client.Client::new(
    backend,
    @sim.FakeClock::new(),
    max_body_bytes=7,
    timeout_ms=80,
  )
  let plan = @client.request(@mttp.Request::get("https://h/"))
  @driver.run_sync(() => {
    for
      request in [
        plan,
        plan.follow_redirects(false).max_redirects(2),
        plan.max_redirects(2),
        plan.max_redirects(-3),
        plan.follow_redirects(false).follow_redirects(true),
      ] {
      ignore(client.send(request.response(@client.ignore_body())))
    }
  })
  assert_eq(seen.map(pair => pair.0), [None, Some(0), Some(2), Some(0), None])
  assert_eq(seen[1].1, { timeout_ms: Some(80), body: Exchange(max_bytes=7), })
}

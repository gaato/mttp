///|
/// Sequential fake time with an explicit suspension supplied by the test;
/// the clock itself has no scheduler or runtime dependency.
priv struct CloseClock {
  mut now : Int64
  sleeps : Array[Int32]
  on_sleep : async () -> Unit noraise
}

///|
impl @rt.Clock for CloseClock with fn now_unix_ms(self) {
  self.now
}

///|
impl @rt.Clock for CloseClock with fn sleep(self, ms) {
  self.sleeps.push(ms)
  (self.on_sleep)()
  self.now += ms.max(0).to_int64()
}

///|
priv struct CloseLimiter {
  mut acquires : Int32
  releases : Array[(Int64, Int32)]
}

///|
impl @client.RateLimiter for CloseLimiter with fn acquire(
  self,
  bucket,
  global_exempt~,
) {
  ignore(global_exempt)
  self.acquires += 1
  @client.Admission::new(bucket, sequence=self.acquires.to_int64())
}

///|
impl @client.RateLimiter for CloseLimiter with fn release(
  self,
  admission,
  status~,
  headers~,
) {
  ignore(headers)
  self.releases.push((admission.sequence(), status))
}

///|
test "close from observer returns the reply without retry wait or admission" {
  for status in [200, 503] {
    let clock = CloseClock::{ now: 0L, sleeps: [], on_sleep: () => (), }
    let limiter = CloseLimiter::{ acquires: 0, releases: [], }
    let holder : Ref[@client.Client?] = Ref(None)
    let calls = Ref(0)
    let closes = Ref(0)
    let observed = []
    let client = @client.Client::new(
      @client.from_fn(
        (_, _) => {
          calls.val += 1
          @mttp_core.Response::new(status, body=Bytes(b"last"))
        },
        on_close=() => closes.val += 1,
      ),
      clock,
      limiter~,
      retry=@client.RetryPolicy::conservative(),
      observer=attempt => {
        observed.push((limiter.releases.copy(), attempt.decision))
        holder.val.unwrap().close()
      },
    )
    holder.val = Some(client)
    let reply = @driver.run_sync(() => {
      client.send(@client.get("/"), decide_retry=(_, _) => Wait(50))
    })
    assert_eq(reply.status, status)
    if status == 200 {
      assert_eq(reply.body, Ok("last"))
    } else {
      assert_true(reply.body is Err(@client.UnexpectedStatus(_, body=b"last")))
    }
    client.close()
    assert_eq(observed, [([(1L, status)], Some(Wait(50)))])
    assert_eq((calls.val, limiter.acquires, closes.val), (1, 1, 1))
    assert_eq(clock.sleeps, [])
  }
}

///|
test "close from observer preserves the last transport failure" {
  let clock = CloseClock::{ now: 0L, sleeps: [], on_sleep: () => (), }
  let limiter = CloseLimiter::{ acquires: 0, releases: [], }
  let holder : Ref[@client.Client?] = Ref(None)
  let calls = Ref(0)
  let failure = @mttp_core.TransportError(
    kind=Connect,
    phase=Dial,
    detail="last",
  )
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      raise failure
    }),
    clock,
    limiter~,
    retry=@client.RetryPolicy::conservative(),
    observer=_ => holder.val.unwrap().close(),
  )
  holder.val = Some(client)
  try {
    ignore(@driver.run_sync(() => client.send(@client.get("/"))))
    fail("lost transport failure")
  } catch {
    @mttp_core.TransportError(..) as error =>
      assert_true(physical_equal(error, failure))
    error => raise error
  }
  assert_eq((calls.val, limiter.acquires), (1, 1))
  assert_eq(limiter.releases, [(1L, 0)])
  assert_eq(clock.sleeps, [])
}

///|
test "close during backoff returns the last outcome on waking without admission" {
  for failing in [false, true] {
    let d = @driver.Driver::new()
    let clock = CloseClock::{ now: 0L, sleeps: [], on_sleep: () => d.pause(), }
    let limiter = CloseLimiter::{ acquires: 0, releases: [], }
    let calls = Ref(0)
    let failure = @mttp_core.TransportError(
      kind=Connect,
      phase=Dial,
      detail="last",
    )
    let client = @client.Client::new(
      @client.from_fn((_, _) => {
        calls.val += 1
        if failing {
          raise failure
        }
        @mttp_core.Response::new(503, body=Bytes(b"last"))
      }),
      clock,
      limiter~,
      retry=@client.RetryPolicy::conservative(),
      random=() => 0.5,
    )
    d.run(() => {
      let close = d.spawn(() => {
        assert_eq(clock.sleeps, [500])
        assert_eq(limiter.releases, [(1L, if failing { 0 } else { 503 })])
        client.close()
      })
      try client.send(@client.get("/")) catch {
        @mttp_core.TransportError(..) as error if failing =>
          assert_true(physical_equal(error, failure))
        error => raise error
      } noraise {
        reply => {
          assert_false(failing)
          assert_eq(reply.status, 503)
          assert_true(
            reply.body is Err(@client.UnexpectedStatus(_, body=b"last")),
          )
        }
      }
      assert_true(close.wait())
    })
    assert_eq((calls.val, limiter.acquires), (1, 1))
    assert_eq(clock.sleeps, [500])
  }
}

///|
test "send after close refuses admission even for a backend that ignores close" {
  let limiter = CloseLimiter::{ acquires: 0, releases: [], }
  let calls = Ref(0)
  let client = @client.Client::new(
    CloseIgnoringBackend::{ calls, },
    CloseClock::{ now: 0L, sleeps: [], on_sleep: () => (), },
    limiter~,
  )
  client.close()
  try {
    ignore(@driver.run_sync(() => client.send(@client.get("/"))))
    fail("closed client sent")
  } catch {
    @mttp_core.TransportError(kind=Closed, phase=Pool, ..) => ()
    error => raise error
  }
  assert_eq((calls.val, limiter.acquires), (0, 0))
  assert_eq(limiter.releases, [])
}

///|
priv struct CloseIgnoringBackend {
  calls : Ref[Int32]
}

///|
impl @mttp_core.Backend for CloseIgnoringBackend with fn send(self, _, _) {
  self.calls.val += 1
  @mttp_core.Response::new(200)
}

///|
priv struct CloseBody {
  mut reads : Int32
  mut closes : Int32
}

///|
impl @mttp_core.BodyStream for CloseBody with fn read_some(self) {
  self.reads += 1
  Some(b"last stream")
}

///|
impl @mttp_core.BodyStream for CloseBody with fn close(self) {
  if self.closes == 0 {
    self.closes = 1
  }
}

///|
test "close before or during backoff preserves the selected stream until consumption" {
  for during_wait in [false, true] {
    let d = @driver.Driver::new()
    let clock = CloseClock::{ now: 0L, sleeps: [], on_sleep: () => d.pause(), }
    let limiter = CloseLimiter::{ acquires: 0, releases: [], }
    let source = CloseBody::{ reads: 0, closes: 0, }
    let holder : Ref[@client.Client?] = Ref(None)
    let client = @client.Client::new(
      @client.from_fn((_, _) => {
        @mttp_core.Response::new(
          200,
          body=Stream(@mttp_core.StreamBody::new(source)),
        )
      }),
      clock,
      limiter~,
      retry=@client.RetryPolicy::conservative(),
      observer=_ => if !during_wait { holder.val.unwrap().close() },
    )
    holder.val = Some(client)
    d.run(() => {
      if during_wait {
        ignore(d.spawn(() => client.close()))
      }
      let reply = client.send(
        @client.get("/").response(
          @client.as_stream((_, stream) => {
            assert_eq(limiter.releases, [(1L, 200)])
            assert_eq(source.closes, 0)
            stream.read_some()
          }),
        ),
        decide_retry=(_, _) => Wait(50),
      )
      assert_eq(reply.body, Ok(Some(b"last stream")))
    })
    assert_eq(limiter.acquires, 1)
    assert_eq((source.reads, source.closes), (1, 1))
    assert_eq(clock.sleeps, if during_wait { [50] } else { [] })
  }
}

///|
test "cancellation during backoff closes the retained stream after releasing admission" {
  let d = @driver.Driver::new()
  let clock = CloseClock::{ now: 0L, sleeps: [], on_sleep: () => d.pause(), }
  let limiter = CloseLimiter::{ acquires: 0, releases: [], }
  let source = CloseBody::{ reads: 0, closes: 0, }
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      @mttp_core.Response::new(
        200,
        body=Stream(@mttp_core.StreamBody::new(source)),
      )
    }),
    clock,
    limiter~,
    retry=@client.RetryPolicy::conservative(),
  )
  d.run(() => {
    let task = d.spawn(() => {
      ignore(
        client.send(
          @client.get("/").response(
            @client.as_stream((_, stream) => stream.read_some()),
          ),
          decide_retry=(_, _) => Wait(50),
        ),
      )
    })
    d.pause()
    assert_eq(clock.sleeps, [50])
    assert_eq(limiter.releases, [(1L, 200)])
    task.cancel()
    assert_false(task.wait())
  })
  assert_eq(limiter.acquires, 1)
  assert_eq((source.reads, source.closes), (0, 1))
}

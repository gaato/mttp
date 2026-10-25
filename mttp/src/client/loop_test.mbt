///|
priv struct RecordingLimiter {
  events : Array[String]
  clock : @fake.FakeClock
  delay : Int32
  fail_release : Bool
}

///|
impl @client.RateLimiter for RecordingLimiter with fn acquire(
  self,
  bucket,
  global_exempt~,
) {
  self.events.push("acquire:\{bucket}:\{global_exempt}")
  self.clock.advance(self.delay)
}

///|
impl @client.RateLimiter for RecordingLimiter with fn release(
  self,
  bucket,
  status~,
  headers~,
) {
  let header = headers.get("x-head").unwrap_or("")
  self.events.push("release:\{bucket}:\{status}:\{header}")
  if self.fail_release {
    raise @client.InvalidRequest(message="release failed")
  }
}

///|
priv struct AlwaysRetry {}

///|
impl @client.RetryDecider for AlwaysRetry with fn decide(_, _, _) {
  Wait(1)
}

///|
priv struct SlowReturnTimer {
  driver : @driver.Driver
}

///|
impl @clock.Timer for SlowReturnTimer with fn within(self, _, callback) {
  callback()
  self.driver.sleep(1000)
  true
}

///|
test "cancelling a timer after its callback completed discards the held stream" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::bytes(d, [b"held"])
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.SimClock::new(d),
    timer=SlowReturnTimer::{ driver: d, },
  )
  d.run(() => {
    let task = d.spawn(() => {
      let _ = client.send(
        @client.request(@model.Request::get("/"))
        .timeout_ms(2000)
        .response(@client.as_stream((_, stream) => stream.read_some())),
      )
    })
    d.pause()
    task.cancel()
    assert_false(task.wait())
  })
  assert_eq(source.reads(), 0)
  assert_eq(source.closes(), 1)
}

///|
test "buffered readers that finish after their deadline fail and retain the head" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::new(d, [Wait(10), Chunk(b"late"), End])
  let observed = []
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.SimClock::new(d),
    observer=a => observed.push(a.status),
  )
  let failed = try {
    let _ = d.run(() => {
      client.send(@client.request(@model.Request::get("/")).timeout_ms(5))
    })
    false
  } catch {
    @model.TransportError(kind=Timeout(ms=5), ..) => true
    error => raise error
  }
  assert_true(failed)
  assert_eq(observed, [200])
  assert_eq(source.closes(), 1)
}

///|
test "a release failure does not replace an existing response error" {
  let clock = @fake.FakeClock::new()
  let limiter = RecordingLimiter::{
    events: [],
    clock,
    delay: 0,
    fail_release: true,
  }
  let observed = []
  let client = @client.Client::new(
    @client.from_handler(_ => @model.Response::new(503)),
    clock,
    limiter~,
    observer=a => observed.push(a.error),
  )
  let failed = try {
    let _ = @driver.run_sync(() => {
      client.send(@client.request(@model.Request::get("/")))
    })
    false
  } catch {
    @client.UnexpectedStatus(head, ..) => head.status == 503
    error => raise error
  }
  assert_true(failed)
  assert_true(observed is [Some(@client.UnexpectedStatus(_, ..))])
}

///|
priv struct WaitingLimiter {
  driver : @driver.Driver
  gate : @fake.SimGate
  releases : Ref[Int32]
}

///|
impl @client.RateLimiter for WaitingLimiter with fn acquire(
  self,
  _,
  global_exempt~,
) {
  let _ = global_exempt
  self.gate.acquire()
}

///|
impl @client.RateLimiter for WaitingLimiter with fn release(
  self,
  _,
  status~,
  headers~,
) {
  let _ = (status, headers)
  self.releases.val += 1
  self.gate.release()
  self.driver.sleep(1000)
}

///|
test "cancellation while awaiting admission releases nothing" {
  let d = @driver.Driver::new()
  let releases = Ref(0)
  let limiter = WaitingLimiter::{
    driver: d,
    gate: @fake.SimGate::new(d, permits=0),
    releases,
  }
  let observed = []
  let client = @client.Client::new(
    @client.from_handler(_ => @model.Response::new(200)),
    @fake.SimClock::new(d),
    limiter~,
    observer=a => observed.push(a.status),
  )
  d.run(() => {
    let task = d.spawn(() => {
      let _ = client.send(@client.request(@model.Request::get("/")))
    })
    d.pause()
    task.cancel()
    assert_false(task.wait())
  })
  assert_eq(releases.val, 0)
  assert_eq(observed, [])
  assert_eq(limiter.gate.waiting(), 0)
}

///|
test "cancellation during release closes the response and observes once" {
  let d = @driver.Driver::new()
  let releases = Ref(0)
  let source = @feed.Feed::bytes(d, [b"unread"])
  let limiter = WaitingLimiter::{
    driver: d,
    gate: @fake.SimGate::new(d),
    releases,
  }
  let observed = []
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    @fake.SimClock::new(d),
    limiter~,
    observer=a => observed.push(a.status),
  )
  d.run(() => {
    let task = d.spawn(() => {
      let _ = client.send(
        @client.request(@model.Request::get("/")).response(
          @client.as_stream((_, stream) => stream.read_some()),
        ),
      )
    })
    d.pause()
    task.cancel()
    assert_false(task.wait())
  })
  assert_eq(releases.val, 1)
  assert_eq(observed, [200])
  assert_eq(source.closes(), 1)
}

///|
test "an attempt that runs out of time is retried for GET not POST" {
  for meth in [@model.Method::Get, Post] {
    let d = @driver.Driver::new()
    let calls = Ref(0)
    let attempts = []
    let backend = @client.from_fn((_, _) => {
      calls.val += 1
      if calls.val == 1 {
        d.sleep(60000)
      }
      @model.Response::new(200, body=Bytes(b"ok"))
    })
    let client = @client.Client::new(
      backend,
      @fake.SimClock::new(d),
      timer=@fake.SimTimer::new(d),
      retry=@client.RetryPolicy::conservative(),
      observer=a => attempts.push((a.attempt, a.status, a.decision)),
    )
    let ok = try {
      let reply = d.run(() => {
        client.send(
          @client.request(@model.Request::new(meth, "/")).timeout_ms(20),
        )
      })
      assert_eq(reply.body, "ok")
      true
    } catch {
      @model.TransportError(kind=Timeout(ms=20), ..) => false
      error => raise error
    }
    assert_eq(ok, meth == Get)
    assert_eq(calls.val, if meth == Get { 2 } else { 1 })
    assert_eq(attempts[0].0, 0)
    assert_eq(attempts[0].1, 0)
    assert_eq(
      attempts[0].2,
      if meth == Get {
        Some(Wait(500))
      } else {
        Some(Stop(MethodNotAllowed))
      },
    )
    assert_eq(d.live_tasks(), 0)
    assert_eq(d.pending_timers(), 0)
  }
}

///|
test "total timeout caps backoff and shrinks attempt budgets" {
  let clock = @fake.FakeClock::new()
  let budgets = []
  let attempts = []
  let client = @client.Client::new(
    @client.from_fn((_, options) => {
      budgets.push(options.timeout_ms)
      clock.advance(100)
      @model.Response::new(500)
    }),
    clock,
    total_ms=1000,
    retry=@client.RetryPolicy::conservative(),
    observer=a => attempts.push(a.decision),
  )
  let failed = try {
    let _ = @driver.run_sync(() => {
      client.send(@client.request(@model.Request::get("/")).timeout_ms(700))
    })
    false
  } catch {
    @client.UnexpectedStatus(_, ..) => true
    error => raise error
  }
  assert_true(failed)
  assert_eq(budgets, [Some(700), Some(400)])
  assert_eq(clock.slept(), [500])
  assert_eq(attempts, [Some(Wait(500)), Some(Stop(Budget(1000)))])
}

///|
test "no attempt starts once total timeout has passed even with custom retry" {
  let clock = @fake.FakeClock::new()
  let budgets = []
  let attempts = []
  let client = @client.Client::new(
    @client.from_fn((_, options) => {
      budgets.push(options.timeout_ms)
      clock.advance(400)
      @model.Response::new(500)
    }),
    clock,
    total_ms=1000,
    retry=AlwaysRetry::{ },
    observer=a => attempts.push(a.attempt),
  )
  let expired = try {
    let _ = @driver.run_sync(() => {
      client.send(@client.request(@model.Request::get("/")))
    })
    false
  } catch {
    @model.TransportError(kind=Timeout(ms=1000), ..) => true
    error => raise error
  }
  assert_true(expired)
  assert_eq(budgets, [Some(1000), Some(599), Some(198)])
  assert_eq(attempts, [0, 1, 2])
}

///|
test "body factory follows admission on every retry and headers survive reader failures" {
  let clock = @fake.FakeClock::new()
  let events = []
  let limiter = RecordingLimiter::{
    events,
    clock,
    delay: 0,
    fail_release: false,
  }
  let calls = Ref(0)
  let client = @client.Client::new(
    @client.from_handler(request => {
      calls.val += 1
      events.push("send:\{calls.val}")
      @model.Response::new(
        200,
        headers=@model.Headers::of([("x-head", "yes")]),
        body=request.body,
      )
    }),
    clock,
    limiter~,
    retry=AlwaysRetry::{ },
    observer=_ => events.push("observe"),
  )
  let reads = Ref(0)
  let request = @client.request(@model.Request::post("/"))
    .attribute(@client.rate_limit_bucket, "b")
    .attribute(@client.global_exempt, true)
    .body_fn(() => {
      events.push("build")
      b"body"
    })
    .response(
      @client.as_string().map(body => {
        reads.val += 1
        if reads.val == 1 {
          raise @client.InvalidRequest(message="retry decoded error")
        }
        body
      }),
    )
  assert_eq(@driver.run_sync(() => client.send(request)).body, "body")
  assert_eq(events, [
    "acquire:b:true", "build", "send:1", "release:b:200:yes", "observe", "acquire:b:true",
    "build", "send:2", "release:b:200:yes", "observe",
  ])
  assert_eq(clock.slept(), [1])
}

///|
test "custom retry cannot replay any stream without a factory" {
  let d = @driver.Driver::new()
  let feed = @feed.Feed::bytes(d, [b"upload"])
  let observed = []
  let sends = Ref(0)
  let client = @client.Client::new(
    @client.from_handler(_ => {
      sends.val += 1
      @model.Response::new(503)
    }),
    @fake.SimClock::new(d),
    retry=AlwaysRetry::{ },
    observer=a => observed.push(a.decision),
  )
  let raw = @model.Request::post("/").body_stream(feed)
  let failed = try {
    let _ = d.run(() => client.send(@client.request(raw)))
    false
  } catch {
    @client.UnexpectedStatus(_, ..) => true
    error => raise error
  }
  assert_true(failed)
  assert_eq(sends.val, 1)
  assert_eq(observed, [Some(Stop(NotReplayable))])
  // A backend that did not acquire the outgoing stream leaves it owned by
  // its creator; the retry loop must not consume it to test replayability.
  assert_eq(feed.reads(), 0)
  feed.close()
}

///|
test "limiter wait uses total budget and still releases before observation" {
  for delay in [0, 11] {
    let clock = @fake.FakeClock::new()
    let events = []
    let limiter = RecordingLimiter::{
      events,
      clock,
      delay,
      fail_release: false,
    }
    let built = Ref(0)
    let client = @client.Client::new(
      @client.from_handler(_ => @model.Response::new(200)),
      clock,
      limiter~,
      total_ms=if delay == 0 { 0 } else { 10 },
      observer=_ => events.push("observe"),
    )
    let failed = try {
      let _ = @driver.run_sync(() => {
        client.send(
          @client.request(@model.Request::get("/")).body_fn(() => {
            built.val += 1
            b"body"
          }),
        )
      })
      false
    } catch {
      @model.TransportError(kind=Timeout(..), ..) => true
      error => raise error
    }
    assert_true(failed)
    assert_eq(built.val, 0)
    assert_eq(
      events,
      if delay == 0 {
        []
      } else {
        ["acquire:default:false", "release:default:0:", "observe"]
      },
    )
  }
}

///|
test "release failure closes accepted stream and is not retried" {
  let d = @driver.Driver::new()
  let feed = @feed.Feed::bytes(d, [b"unread"])
  let clock = @fake.FakeClock::new()
  let events = []
  let observed = []
  let limiter = RecordingLimiter::{
    events,
    clock,
    delay: 0,
    fail_release: true,
  }
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(feed)))
    }),
    clock,
    limiter~,
    retry=AlwaysRetry::{ },
    observer=a => observed.push(a),
  )
  let failed = try {
    let _ = d.run(() => {
      client.send(
        @client.request(@model.Request::get("/")).response(
          @client.as_stream((_, stream) => stream.read_some()),
        ),
      )
    })
    false
  } catch {
    @client.InvalidRequest(message="release failed") => true
    error => raise error
  }
  assert_true(failed)
  assert_eq(feed.reads(), 0)
  assert_eq(feed.closes(), 1)
  assert_eq(observed.length(), 1)
  assert_eq(observed[0].status, 200)
  assert_true(observed[0].error is Some(@client.InvalidRequest(..)))
}

///|
test "cancellation after a head releases its status and closes the body" {
  let d = @driver.Driver::new()
  let feed = @feed.Feed::new(d, [Wait(1000), Chunk(b"later"), End])
  let clock = @fake.FakeClock::new()
  let events = []
  let observed = []
  let limiter = RecordingLimiter::{
    events,
    clock,
    delay: 0,
    fail_release: false,
  }
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(feed)))
    }),
    clock,
    limiter~,
    observer=a => observed.push(a),
  )
  d.run(() => {
    let task = d.spawn(() => {
      let _ = client.send(@client.request(@model.Request::get("/")))
    })
    d.pause()
    task.cancel()
    assert_false(task.wait())
  })
  assert_eq(events, ["acquire:default:false", "release:default:200:"])
  assert_eq(observed.length(), 1)
  assert_eq(observed[0].status, 200)
  assert_eq(feed.closes(), 1)
}

///|
test "cancellation survives a failing release and is observed once" {
  let d = @driver.Driver::new()
  let source = @feed.Feed::new(d, [Wait(1000), End])
  let clock = @fake.FakeClock::new()
  let limiter = RecordingLimiter::{
    events: [],
    clock,
    delay: 0,
    fail_release: true,
  }
  let observed = []
  let client = @client.Client::new(
    @client.from_handler(_ => {
      @model.Response::new(200, body=Stream(@model.StreamBody::new(source)))
    }),
    clock,
    limiter~,
    observer=a => observed.push(a.status),
  )
  d.run(() => {
    let task = d.spawn(() => {
      let _ = client.send(@client.request(@model.Request::get("/")))
    })
    d.pause()
    task.cancel()
    assert_false(task.wait())
  })
  assert_eq(observed, [200])
  assert_eq(limiter.events, ["acquire:default:false", "release:default:200:"])
  assert_eq(source.closes(), 1)
}

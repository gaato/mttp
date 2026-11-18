///|
/// A one-line description of an event, for comparing whole sequences.
fn describe(event : @client.ClientEvent) -> String {
  match event {
    AttemptStart(request~, attempt~, bucket~, ..) =>
      "start \{attempt} \{request.meth} \{request.url} \{bucket}"
    Phase(attempt~, phase~, ..) => "phase \{attempt} \{phase_text(phase)}"
    AttemptEnd(info, ..) => "end \{info.attempt} \{info.status}"
    Retry(attempt~, wait_ms~, reason~, ..) =>
      "retry \{attempt} \{wait_ms} \{reason}"
    Redirect(from~, to~, status~, ..) => "redirect \{status} \{from} \{to}"
    @client.ClientEvent::.. => "other"
  }
}

///|
fn phase_text(phase : @mttp_core.PhaseEvent) -> String {
  match phase {
    Dialed(addr~) => "dialed \{addr}"
    TlsDone => "tls"
    Pooled(reused~) => "pooled \{reused}"
    Written => "written"
    FirstByte => "first-byte"
    @mttp_core.PhaseEvent::.. => "other"
  }
}

///|
fn event_send_id(event : @client.ClientEvent) -> Int64 {
  match event {
    AttemptStart(send_id~, ..)
    | Phase(send_id~, ..)
    | AttemptEnd(_, send_id~)
    | Retry(send_id~, ..)
    | Redirect(send_id~, ..) => send_id
    @client.ClientEvent::.. => abort("unexpected event")
  }
}

///|
test "concurrent sends have distinct ids preserved across every redirect and retry event" {
  let d = @driver.Driver::new()
  let calls : Map[String, Int32] = Map([])
  let log = []
  let starts = []
  let client = @client.Client::new(
    @client.from_fn((request, _) => {
      let phase = request.attributes.get(@mttp_core.on_phase).unwrap()
      phase(Written)
      let count = calls.get(request.url).unwrap_or(0) + 1
      calls[request.url] = count
      d.pause()
      phase(FirstByte)
      if request.url.has_suffix("/start") {
        @mttp_core.Response::new(
          302,
          headers=@mttp_core.Headers::of([("location", "end")]),
        )
      } else {
        @mttp_core.Response::new(if count == 1 { 503 } else { 200 })
      }
    }),
    @sim.FakeClock::new(),
    retry=@client.RetryPolicy::conservative(),
    events=event => {
      let id = event_send_id(event)
      log.push((id, describe(event)))
      if event is AttemptStart(request~, attempt=0, ..) {
        starts.push((id, request.url))
      }
    },
  )
  d.run(() => {
    let tasks = [
      for name in ["a", "b"] => {
        d.spawn(() => {
          let reply = client.send(
            @client.get("http://example.test/\{name}/start"),
            decide_retry=(_, context) => {
              if context.attempt == 0 {
                Wait(0)
              } else {
                Stop(NotRetryable)
              }
            },
          )
          assert_eq(reply.status, 200)
        })
      }
    ]
    for task in tasks {
      assert_true(task.wait())
    }
  })
  assert_eq(starts.length(), 2)
  assert_true(starts[0].0 != starts[1].0)
  for (id, url) in starts {
    let end = url.replace(old="start", new="end")
    let events = log.filter(entry => entry.0 == id).map(entry => entry.1)
    assert_eq(events, [
      "start 0 GET \{url} default",
      "phase 0 written",
      "phase 0 first-byte",
      "redirect 302 \{url} \{end}",
      "phase 0 written",
      "phase 0 first-byte",
      "end 0 503",
      "retry 1 0 503",
      "start 1 GET \{url} default",
      "phase 1 written",
      "phase 1 first-byte",
      "redirect 302 \{url} \{end}",
      "phase 1 written",
      "phase 1 first-byte",
      "end 1 200",
    ])
  }
}

///|
/// A stub that reports `Written` and `FirstByte` for every exchange, as an
/// engine that cannot see connections would, and answers with `answer`.
fn reporting(
  answer : (@mttp_core.Request) -> @mttp_core.Response,
) -> &@mttp_core.Backend {
  @client.from_fn((request, _) => {
    if request.attributes.get(@mttp_core.on_phase) is Some(report) {
      report(Written)
      report(FirstByte)
    }
    answer(request)
  })
}

///|
priv struct EventLimiter {
  mut acquires : Int32
  mut releases : Int32
  retry_acquire : async () -> Unit
}

///|
impl @client.RateLimiter for EventLimiter with fn acquire(
  self,
  bucket,
  global_exempt~,
) {
  ignore(global_exempt)
  self.acquires += 1
  if self.acquires > 1 {
    (self.retry_acquire)()
  }
  @client.Admission::new(bucket, sequence=self.acquires.to_int64())
}

///|
impl @client.RateLimiter for EventLimiter with fn release(
  self,
  _,
  status~,
  headers~,
) {
  ignore((status, headers))
  self.releases += 1
}

///|
test "Retry is absent when the next admission is cancelled, expires or raises" {
  for mode in ["cancel", "deadline", "failure"] {
    let d = @driver.Driver::new()
    let clock = @sim.FakeClock::new()
    let blocked = @sim.SimCoordination::new(d).signal()
    let entering = @sim.SimCoordination::new(d).signal()
    let entered = Ref(false)
    let limiter = EventLimiter::{
      acquires: 0,
      releases: 0,
      retry_acquire: () => {
        entered.val = true
        entering.notify()
        if mode == "failure" {
          raise @mttp_core.TransportError(
            kind=Refused,
            phase=Pool,
            detail="admission refused",
          )
        }
        blocked.wait()
      },
    }
    let log = []
    let calls = Ref(0)
    let client = @client.Client::new(
      @client.from_fn((_, _) => {
        calls.val += 1
        @mttp_core.Response::new(503)
      }),
      clock,
      limiter~,
      timer=@sim.SimTimer::new(d),
      total_ms?=if mode == "deadline" { Some(10) } else { None },
      retry=@client.RetryPolicy::conservative(),
      events=event => log.push(describe(event)),
    )
    d.run(() => {
      let task = d.spawn(() => {
        try
          client.send(@client.get("http://example.test/"), decide_retry=(_, _) => {
            Wait(0)
          })
        catch {
          @mttp_core.TransportError(kind=Timeout(..), ..) if mode == "deadline" =>
            ()
          @mttp_core.TransportError(kind=Refused, phase=Pool, ..) if mode ==
            "failure" => ()
          error => raise error
        } noraise {
          _ => fail("the retry should not be admitted")
        }
      })
      entering.wait()
      assert_true(entered.val)
      if mode == "cancel" {
        task.cancel()
      }
      assert_eq(task.wait(), mode != "cancel")
    })
    assert_eq((calls.val, limiter.acquires, limiter.releases), (1, 2, 1))
    assert_eq(log, ["start 0 GET http://example.test/ default", "end 0 503"])
  }
}

///|
test "a plain request reports its start, the backend's phases and its end, beside the observer" {
  let log = []
  let observed = []
  let client = @client.Client::new(
    reporting(_ => @mttp_core.Response::new(200)),
    @sim.FakeClock::new(),
    observer=attempt => observed.push(attempt.status),
    events=event => log.push(describe(event)),
  )
  let reply = @driver.run_sync(() => {
    client.send(@client.get("http://example.test/a"))
  })
  assert_eq(reply.status, 200)
  assert_eq(log, [
    "start 0 GET http://example.test/a default", "phase 0 written", "phase 0 first-byte",
    "end 0 200",
  ])
  assert_eq(observed, [200])
}

///|
test "a redirect is reported between the phases of its two hops" {
  let log = []
  let client = @client.Client::new(
    reporting(request => {
      if request.url.has_suffix("/old") {
        @mttp_core.Response::new(
          302,
          headers=@mttp_core.Headers::of([("location", "/new")]),
        )
      } else {
        @mttp_core.Response::new(200)
      }
    }),
    @sim.FakeClock::new(),
    events=event => log.push(describe(event)),
  )
  let reply = @driver.run_sync(() => {
    client.send(@client.get("http://example.test/old"))
  })
  assert_eq(reply.status, 200)
  assert_eq(log, [
    "start 0 GET http://example.test/old default", "phase 0 written", "phase 0 first-byte",
    "redirect 302 http://example.test/old http://example.test/new", "phase 0 written",
    "phase 0 first-byte", "end 0 200",
  ])
}

///|
test "a retry is reported between the attempts, with its wait and the status that caused it" {
  let log = []
  let calls = Ref(0)
  let clock = @sim.FakeClock::new()
  let client = @client.Client::new(
    reporting(_ => {
      calls.val += 1
      @mttp_core.Response::new(if calls.val == 1 { 503 } else { 200 })
    }),
    clock,
    retry=@client.RetryPolicy::conservative(),
    events=event => log.push(describe(event)),
  )
  let reply = @driver.run_sync(() => {
    client.send(@client.get("http://example.test/"), decide_retry=(_, context) => {
      if context.attempt == 0 {
        Wait(25)
      } else {
        context.default_decision
      }
    })
  })
  assert_eq(reply.status, 200)
  assert_eq(log, [
    "start 0 GET http://example.test/ default", "phase 0 written", "phase 0 first-byte",
    "end 0 503", "retry 1 25 503", "start 1 GET http://example.test/ default", "phase 1 written",
    "phase 1 first-byte", "end 1 200",
  ])
}

///|
test "a retry after a transport failure names the failure's kind" {
  let log = []
  let calls = Ref(0)
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      calls.val += 1
      if calls.val == 1 {
        raise @mttp_core.TransportError(
          kind=Connect,
          phase=Dial,
          detail="refused",
        )
      }
      @mttp_core.Response::new(200)
    }),
    @sim.FakeClock::new(),
    retry=@client.RetryPolicy::conservative(),
    random=() => 0.0,
    events=event => log.push(describe(event)),
  )
  let reply = @driver.run_sync(() => {
    client.send(@client.get("http://example.test/"))
  })
  assert_eq(reply.status, 200)
  assert_eq(log.length(), 5)
  assert_eq(log[1], "end 0 0")
  assert_true(log[2].has_prefix("retry 1 "))
  assert_true(log[2].has_suffix(" connect"))
}

///|
test "over the HTTP/1.1 engine, a second send reuses the pooled connection" {
  let driver = @driver.Driver::new()
  let conn = @sim.ScriptedConn::new([
    Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none"),
    Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo"),
  ])
  let engine = @h1client.Client::new(
    dialer=@sim.ScriptedDialer::new([conn]),
    clock=@sim.SimClock::new(driver),
    timer=@sim.SimTimer::new(driver),
    coordination=@sim.SimCoordination::new(driver),
    config=@h1client.ClientConfig::default(),
  )
  let log = []
  let client = @client.Client::new(engine, @sim.SimClock::new(driver), events=event => {
    log.push(describe(event))
  })
  driver.run(() => {
    let first = client.send(@client.get("http://example.test/1"))
    let second = client.send(@client.get("http://example.test/2"))
    assert_eq(first.body, Ok("one"))
    assert_eq(second.body, Ok("two"))
    client.close()
  })
  assert_eq(log, [
    "start 0 GET http://example.test/1 default", "phase 0 dialed example.test:80",
    "phase 0 pooled false", "phase 0 written", "phase 0 first-byte", "end 0 200",
    "start 0 GET http://example.test/2 default", "phase 0 pooled true", "phase 0 written",
    "phase 0 first-byte", "end 0 200",
  ])
}

///|
test "no event follows a cancelled attempt's end, even a late phase report" {
  let d = @driver.Driver::new()
  let clock = @sim.SimClock::new(d)
  let late : Ref[((@mttp_core.PhaseEvent) -> Unit)?] = Ref(None)
  let log = []
  let client = @client.Client::new(
    @client.from_fn((request, _) => {
      let report = request.attributes.get(@mttp_core.on_phase).unwrap()
      late.val = Some(report)
      report(Dialed(addr="example.test:80"))
      clock.sleep(1000)
      report(Written)
      @mttp_core.Response::new(200)
    }),
    clock,
    retry=@client.RetryPolicy::conservative(),
    events=event => log.push(describe(event)),
  )
  d.run(() => {
    let task = d.spawn(() => {
      ignore(client.send(@client.get("http://example.test/")))
    })
    d.pause()
    task.cancel()
    assert_false(task.wait())
  })
  match late.val {
    Some(report) => report(FirstByte)
    None => fail("the backend never ran")
  }
  assert_eq(log, [
    "start 0 GET http://example.test/ default", "phase 0 dialed example.test:80",
    "end 0 0",
  ])
}

///|
test "a Client without events adds no phase callback to the request" {
  let seen = []
  let client = @client.Client::new(
    @client.from_fn((request, _) => {
      seen.push(request.attributes.get(@mttp_core.on_phase) is Some(_))
      @mttp_core.Response::new(204)
    }),
    @sim.FakeClock::new(),
  )
  let reply = @driver.run_sync(() => {
    client.send(@client.get("http://example.test/"))
  })
  assert_eq(reply.status, 204)
  assert_eq(seen, [false])
}

///|
test "a request's own on_phase is still called beside the Client's events" {
  let own = []
  let log = []
  let client = @client.Client::new(
    reporting(_ => @mttp_core.Response::new(200)),
    @sim.FakeClock::new(),
    events=event => log.push(describe(event)),
  )
  let reply = @driver.run_sync(() => {
    client.send(
      @client.get("http://example.test/a").attribute(@mttp_core.on_phase, phase => {
        own.push(phase)
      }),
    )
  })
  assert_eq(reply.status, 200)
  assert_eq(own, [Written, FirstByte])
  assert_eq(log, [
    "start 0 GET http://example.test/a default", "phase 0 written", "phase 0 first-byte",
    "end 0 200",
  ])
}

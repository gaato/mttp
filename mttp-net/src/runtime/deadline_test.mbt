///|
priv struct AdmissionWait {
  entered : @aqueue.Queue[Unit]
  releases : Ref[Int32]
}

///|
impl @client.RateLimiter for AdmissionWait with fn acquire(
  self,
  _,
  global_exempt~,
) {
  ignore(global_exempt)
  self.entered.put(())
  @cond_var.Cond().wait()
}

///|
impl @client.RateLimiter for AdmissionWait with fn release(
  self,
  _,
  status~,
  headers~,
) {
  ignore((status, headers))
  self.releases.val += 1
}

///|
async test "whole call deadline cancels admission before body preparation" {
  let clock = ControlledClock::new()
  let limiter = AdmissionWait::{
    entered: @aqueue.Queue(kind=Unbounded),
    releases: Ref(0),
  }
  let prepared = Ref(0)
  let sent = Ref(0)
  let expired = Ref(false)
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      sent.val += 1
      @model.Response::new(200)
    }),
    clock,
    limiter~,
    total_ms=10,
    timer=@runtime.ClockTimer::new(clock~),
    options={ ..@client.RequestOptions::default(), timeout_ms: None, },
  )
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      try {
        let _ = @client.get("/")
          .body_fn(() => {
            prepared.val += 1
            b""
          })
          .send(client)
        fail("deadline did not cancel admission")
      } catch {
        @model.TransportError(kind=Timeout(ms=10), ..) => expired.val = true
        error => raise error
      }
    })
    assert_eq(clock.started.get(), 10)
    limiter.entered.get()
    clock.wake.signal()
  })
  assert_true(expired.val)
  assert_eq(
    (prepared.val, sent.val, limiter.releases.val, clock.pending),
    (0, 0, 0, 0),
  )
}

///|
priv struct DeadlineBody {
  closes : Ref[Int32]
  mut closed : Bool
}

///|
impl @model.BodyStream for DeadlineBody with fn read_some(self) {
  if self.closed {
    None
  } else {
    Some(b"chunk")
  }
}

///|
impl @model.BodyStream for DeadlineBody with fn close(self) {
  if !self.closed {
    self.closed = true
    self.closes.val += 1
  }
}

///|
async test "whole call deadline cancels stream consumer and completes its required cleanup" {
  let clock = ControlledClock::new()
  let closes = Ref(0)
  let cleaned = Ref(0)
  let started : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
  let expired = Ref(false)
  let sends = Ref(0)
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      sends.val += 1
      @model.Response::new(
        200,
        body=Stream(
          @model.StreamBody::new(DeadlineBody::{ closes, closed: false, }),
        ),
      )
    }),
    clock,
    total_ms=10,
    timer=@runtime.ClockTimer::new(clock~),
    options={ ..@client.RequestOptions::default(), timeout_ms: None, },
    retry=@client.RetryPolicy::conservative(),
  )
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      try {
        let _ = @client.get("/")
          .response(
            @client.as_stream((_, stream) => {
              defer @async.protect_from_cancel(() => {
                @async.pause()
                cleaned.val += 1
              })
              assert_eq(stream.read_some(), Some(b"chunk"))
              started.put(())
              @cond_var.Cond().wait()
            }),
          )
          .send(client)
        fail("deadline did not cancel consumer")
      } catch {
        @model.TransportError(kind=Timeout(ms=10), ..) => expired.val = true
        error => raise error
      }
    })
    assert_eq(clock.started.get(), 10)
    started.get()
    clock.wake.signal()
  })
  assert_true(expired.val)
  assert_eq((sends.val, closes.val, cleaned.val, clock.pending), (1, 1, 1, 0))
}

///|
priv struct RollbackRelease {
  entered : @aqueue.Queue[Unit]
  held : Ref[Bool]
  releases : Ref[Int32]
}

///|
impl @client.RateLimiter for RollbackRelease with fn acquire(
  self,
  _,
  global_exempt~,
) {
  ignore(global_exempt)
  self.held.val = true
}

///|
impl @client.RateLimiter for RollbackRelease with fn release(
  self,
  _,
  status~,
  headers~,
) {
  ignore((status, headers))
  self.releases.val += 1
  // A remote lease implementation must compensate if its release is cancelled.
  errdefer {
    self.held.val = false
  }
  self.entered.put(())
  @cond_var.Cond().wait()
  self.held.val = false
}

///|
async test "deadline during release rolls back once and closes a held response" {
  let clock = ControlledClock::new()
  let closes = Ref(0)
  let observed = Ref(0)
  let limiter = RollbackRelease::{
    entered: @aqueue.Queue(kind=Unbounded),
    held: Ref(false),
    releases: Ref(0),
  }
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      @model.Response::new(
        200,
        body=Stream(
          @model.StreamBody::new(DeadlineBody::{ closes, closed: false, }),
        ),
      )
    }),
    clock,
    limiter~,
    total_ms=10,
    timer=@runtime.ClockTimer::new(clock~),
    observer=_ => observed.val += 1,
    options={ ..@client.RequestOptions::default(), timeout_ms: None, },
  )
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      try {
        let _ : @client.Reply[Result[Unit, @client.ResponseFailure]] = @client.get(
            "/",
          )
          .response(@client.as_stream((_, _) => fail("consumer started")))
          .send(client)
        fail("deadline did not cancel release")
      } catch {
        @model.TransportError(kind=Timeout(ms=10), ..) => ()
        error => raise error
      }
    })
    assert_eq(clock.started.get(), 10)
    limiter.entered.get()
    clock.wake.signal()
  })
  assert_false(limiter.held.val)
  assert_eq(
    (limiter.releases.val, observed.val, closes.val, clock.pending),
    (1, 1, 1, 0),
  )
}

///|
suberror CallbackMarker {
  CallbackMarker(Int32)
}

///|
async test "total timer preserves unknown callback exception identity" {
  let clock = @runtime.AsyncClock::new()
  let sends = Ref(0)
  let client = @client.Client::new(
    @client.from_fn((_, _) => {
      sends.val += 1
      @model.Response::new(200)
    }),
    clock,
    total_ms=10000,
    timer=@runtime.ClockTimer::new(clock~),
    retry=@client.RetryPolicy::conservative(),
  )
  try {
    let _ : @client.Reply[Result[Unit, @client.ResponseFailure]] = @client.get(
        "/",
      )
      .response(@client.as_stream((_, _) => raise CallbackMarker(7)))
      .send(client)
    fail("callback exception lost")
  } catch {
    CallbackMarker(7) => ()
    error => raise error
  }
  assert_eq(sends.val, 1)
}

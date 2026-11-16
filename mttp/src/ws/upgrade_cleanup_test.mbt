///|
priv struct CancelUpgrade {
  inner : &@rt.Upgraded
  cancel : () -> Unit
}

///|
priv struct ReleaseBarrier {
  entered : &@rt.Signal
  forever : &@rt.Signal
}

///|
impl @client.RateLimiter for ReleaseBarrier with fn acquire(
  _,
  bucket,
  global_exempt~,
) {
  ignore(global_exempt)
  @client.Admission::new(bucket, sequence=1L)
}

///|
impl @client.RateLimiter for ReleaseBarrier with fn release(
  self,
  _,
  status~,
  headers~,
) {
  ignore((status, headers))
  self.entered.notify()
  self.forever.wait()
}

///|
async test "Client decoder failure and release cancellation free a real h1 origin slot" {
  for cancel in [false, true] {
    let (engine, wire) = upgrade_engine()
    defer engine.close()
    let coordination = @runtime.RuntimeCoordination::new()
    let entered = coordination.signal()
    let limiter : &@client.RateLimiter = if cancel {
      ReleaseBarrier::{ entered, forever: coordination.signal(), }
      as &@client.RateLimiter
    } else {
      @client.NoLimiter::new() as &@client.RateLimiter
    }
    let c = @client.Client::new(engine, @runtime.AsyncClock::new(), limiter~)
    defer c.close()
    let raw = @handshake.client_request(
      "ws://example.test/",
      key="dGhlIHNhbXBsZSBub25jZQ==",
    )
    if cancel {
      @async.with_task_group(group => {
        let task = group.spawn(allow_failure=true, () => {
          ignore(c.send(@client.request(raw)))
        })
        entered.wait()
        task.cancel()
        task.wait() catch {
          @async.WaitedTaskAlreadyCancelled => ()
          error => raise error
        }
      })
    } else {
      let decoder : @client.ResponseAs[Unit] = @client.ResponsePlan::new((_, _) => {
        raise @client.InvalidRequest(message="decode failed")
      })
      try c.send(@client.request(raw).response(decoder)) catch {
        @client.InvalidRequest(..) => ()
        _ => fail("wrong failure")
      } noraise {
        _ => fail("decoder passed")
      }
    }
    upgrade_slot_free(engine, wire)
    c.close()
    assert_eq(wire.closes(), 1)
  }
}

///|
impl @rt.Upgraded for CancelUpgrade with fn take_conn(self) {
  let taken = self.inner.take_conn()
  (self.cancel)()
  taken
}

///|
fn upgrade_engine() -> (@h1client.Client, @sim.ScriptedConn) {
  let wire = @sim.ScriptedConn::new([
    Chunk(b"HTTP/1.1 101 Switching Protocols\r\n\r\n"),
  ])
  let next = @sim.ScriptedConn::new([
    Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"),
  ])
  let engine = @h1client.Client::new(
    dialer=@sim.ScriptedDialer::new([wire, next]),
    clock=@runtime.AsyncClock::new(),
    timer=@runtime.ClockTimer::new(),
    coordination=@runtime.RuntimeCoordination::new(),
    config={
      ..@h1client.ClientConfig::default(),
      max_connections: Some(1),
      max_connections_per_origin: Some(1),
      pool_timeout_ms: Some(50),
    },
  )
  (engine, wire)
}

///|
async fn upgrade_slot_free(
  engine : @h1client.Client,
  wire : @sim.ScriptedConn,
) -> Unit {
  assert_eq(wire.closes(), 1)
  let response = engine.send(
    @mttp_core.Request::get("http://example.test/"),
    @mttp_core.SendOptions::default(),
  )
  assert_eq(response.status, 200)
  response.close()
  engine.close()
  engine.close()
  assert_eq(wire.closes(), 1)
}

///|
async test "ws connect failed handshake closes the real engine connection and frees its slot" {
  let (engine, wire) = upgrade_engine()
  defer engine.close()
  try @ws.connect("ws://example.test/", backend=engine) catch {
    @core_ws.WsError(kind=Handshake(_), ..) => ()
    _ => fail("unexpected error")
  } noraise {
    _ => fail("accepted invalid handshake")
  }
  upgrade_slot_free(engine, wire)
}

///|
async test "ws connect cancellation requested at response or take cannot orphan the real engine slot" {
  for during_take in [false, true] {
    let (engine, wire) = upgrade_engine()
    defer engine.close()
    let ready = @runtime.RuntimeCoordination::new().signal()
    let cancel : Ref[() -> Unit] = Ref(() => ())
    let backend = @client.from_fn((request, options) => {
      let response = engine.send(request, options)
      let key = request.headers.get("sec-websocket-key").unwrap()
      let inner = response.attributes.get(@rt.upgraded).unwrap()
      let response = {
        ..response,
        headers: @mttp_core.Headers::of([
          ("connection", "Upgrade"),
          ("upgrade", "websocket"),
          ("sec-websocket-accept", @handshake.accept_value(key)),
        ]),
        attributes: response.attributes.put(@rt.upgraded, CancelUpgrade::{
          inner,
          cancel: () => if during_take { (cancel.val)() },
        }),
      }
      if !during_take {
        (cancel.val)()
      }
      response
    })
    let delivered = Ref(false)
    @async.with_task_group(group => {
      let task = group.spawn(allow_failure=true, () => {
        ready.wait()
        let session = @ws.connect("ws://example.test/", backend~)
        defer session.abort()
        delivered.val = true
        @async.pause()
      })
      cancel.val = () => task.cancel()
      ready.notify()
      task.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        error => raise error
      }
    })
    // The hand-over and constructor contain no suspension: pending cancel
    // reaches the caller only after it owns the session and installs cleanup.
    assert_true(delivered.val)
    upgrade_slot_free(engine, wire)
  }
}

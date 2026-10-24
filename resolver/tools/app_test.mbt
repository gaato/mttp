///|
fn run_async(f : async () -> Unit noraise + nocancel) = "%async.run"

///|
async fn[X] capture_cancellation(
  f : async () -> X,
  handler~ : async () -> X nocancel,
) -> X nocancel = "%async.capture_cancellation"

///|
fn[X] run_sync(f : async () -> X) -> X? {
  let mut result : X? = None
  run_async(async fn() noraise + nocancel {
    let r = try {
      Some(capture_cancellation(f, handler=async fn() nocancel { abort("cancelled") }))
    } catch {
      _ => None
    }
    result = r
  })
  result
}

///|
test "old-world impls flow into the new API and back" {
  let ac = @asyncrt.AsyncClock::new()
  let gate = @asyncrt.SemaphoreGate::new()
  let timer = @asyncrt.ClockTimer::new(clock=ac)
  let old = @sdkrt.Policy::new(clock=ac, timer~, gate~)
  let p = @mttp.Policy::new(ac, timer~, gate~)
  let tick = @sdkrt.TickClock::new()
  let p2 = @mttp.Policy::new(tick)
  let fc = @sdkrt.fake_clock()
  let p3 = @mttp.Policy::new(fc)
  let newfake = @fake.FakeClock::new(start_unix_ms=100L)
  let old2 = @sdkrt.Policy::new(clock=newfake)
  let same : @mock.FakeClock = newfake
  let out = run_sync(async fn() {
    [p.wait(10), old.backoff(5), p2.wait(7), p3.wait(3), old2.backoff(1)]
  })
  debug_inspect(out, content="Some([1010, 1015, 7, 9, 101])")
  debug_inspect(@sdkrt.fake_slept(fc), content="[3]")
  debug_inspect(@sdkrt.fake_slept(same), content="[1]")
  debug_inspect(@sdkrt.stamp(ac), content="1015")
  debug_inspect(ac.now_unix_ms(), content="1015")
  debug_inspect(@sdkrt.transport_now(newfake), content="101")
  debug_inspect(@sdkrt.Describe::describe(same), content="\"fake@101\"")
  debug_inspect(gate.permits(), content="1")
  debug_inspect(@sdkrt.jitter(old), content="0.5")
  debug_inspect(@http.version(), content="\"http 0.5.1 shim\"")
}

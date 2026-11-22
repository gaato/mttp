///|
async fn yield_once() -> Unit noraise {
  @mono.wait_for(0) catch {
    _ => ()
  }
}

///|
async fn stage2() -> Unit {
  @sim.check_coordination_contract(WasiCoordination::{  }, suspend=yield_once)
  say("stage2: check_coordination_contract passed")
  let clock = WasiClock::{  }
  let timer = WasiTimer::{ clock, }
  // within: nonpositive does not start f.
  let started = Ref(false)
  guard !timer.within(0, () => started.val = true) && !started.val else {
    fail("within(0) started f")
  }
  // within: f finishing returns true.
  guard timer.within(1000, () => clock.sleep(10)) else {
    fail("within(1000) of a 10 ms sleep returned false")
  }
  // within: expiry cancels f, and returns after f has unwound.
  let unwound = Ref(false)
  let t0 = clock.now_unix_ms()
  let ok = timer.within(50, () => {
    defer { unwound.val = true }
    clock.sleep(10_000)
  })
  let took = clock.now_unix_ms() - t0
  guard !ok && unwound.val && took < 1000 else {
    fail("within(50) of a 10 s sleep: ok=\{ok} unwound=\{unwound.val} took=\{took}")
  }
  // within: cancelling the caller cancels f and disarms the deadline.
  let inner_unwound = Ref(false)
  let outer = timer.within(30, () => {
    ignore(timer.within(10_000, () => {
      defer { inner_unwound.val = true }
      clock.sleep(10_000)
    }))
  })
  guard !outer && inner_unwound.val else {
    fail("nested within: outer=\{outer} inner unwound=\{inner_unwound.val}")
  }
  // Gate: FIFO, and a cancelled waiter leaves the queue.
  let gate = WasiGate::new(permits=1)
  let order = []
  gate.acquire()
  @async-core.with_task_group(group => {
    group.spawn_bg(() => { gate.acquire(); order.push(1); gate.release() })
    group.spawn_bg(() => {
      ignore(timer.within(20, () => { gate.acquire(); order.push(99); gate.release() }))
    })
    group.spawn_bg(() => { gate.acquire(); order.push(2); gate.release() })
    clock.sleep(60)
    gate.release()
  })
  guard order == [1, 2] else { fail("gate order \{order}") }
  say("stage2: Timer and Gate checks passed (took \{took} ms for a 50 ms expiry)")
}

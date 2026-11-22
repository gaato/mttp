// mttp_core's runtime ports over wit-bindgen-moonbit's async-core and
// wasi:clocks@0.3.0. Ported from mttp/src/runtime (core/async), whose API
// async-core follows; differences are noted where they occur.

///|
pub struct WasiClock {}

///|
pub impl @rt.Clock for WasiClock with fn sleep(_, ms) {
  if ms > 0 {
    // wait-for is an async import: its subtask is cancelled with the caller.
    @mono.wait_for(ms.to_uint64() * 1_000_000UL) catch {
      _ => ()
    }
  }
}

///|
pub impl @rt.Clock for WasiClock with fn now_unix_ms(_) {
  let t = @sysclock.now()
  t.seconds * 1000L + (t.nanoseconds / 1_000_000U).to_int64()
}

///|
pub struct WasiTimer {
  clock : &@rt.Clock
}

///|
pub impl @rt.Timer for WasiTimer with fn within(self, ms, f) {
  if ms <= 0 {
    return false
  }
  let finished = Ref(false)
  @async-core.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      self.clock.sleep(ms)
      group.return_immediately(())
    })
    f()
    finished.val = true
  }) catch {
    _ => ()
  }
  finished.val
}

///|
pub struct WasiGate {
  semaphore : @async-core.Semaphore
  mut held : Int
}

///|
pub fn WasiGate::new(permits~ : Int = 1) -> WasiGate {
  {
    semaphore: @async-core.Semaphore(
      permits.max(1),
      initial_value=permits.max(0),
    ),
    held: 0,
  }
}

///|
pub impl @rt.Gate for WasiGate with fn acquire(self) {
  self.semaphore.acquire()
  self.held += 1
}

///|
pub impl @rt.Gate for WasiGate with fn release(self) {
  if self.held > 0 {
    self.held -= 1
    self.semaphore.release()
  }
}

///|
priv struct WasiSignal {
  mut notified : Bool
  changed : @async-core.CondVar
}

///|
impl @rt.Signal for WasiSignal with fn wait(self) {
  while !self.notified {
    self.changed.wait()
  }
}

///|
impl @rt.Signal for WasiSignal with fn notify(self) {
  self.notified = true
  self.changed.broadcast()
}

///|
pub struct WasiCoordination {}

///|
fn as_transport(error : Error) -> @mttp.TransportError {
  match error {
    @mttp.TransportError(..) as e => e
    e => @mttp.TransportError(kind=Network, phase=Unknown, detail=e.to_string())
  }
}

///|
pub impl @rt.Coordination for WasiCoordination with fn protect(_, work~) {
  @async-core.protect_from_cancel(() => work()) catch {
    e => raise as_transport(e)
  }
}

///|
pub impl @rt.Coordination for WasiCoordination with fn signal(_) {
  WasiSignal::{ notified: false, changed: @async-core.CondVar() }
}

///|
pub impl @rt.Coordination for WasiCoordination with fn supervise(
  _,
  primary~,
  monitor~,
) {
  let failure : Ref[@mttp.TransportError?] = Ref(None)
  let completed = Ref(false)
  @async-core.with_task_group(group => {
    group.spawn_bg(no_wait=true, () => {
      monitor() catch {
        error =>
          if !completed.val {
            if failure.val is None {
              failure.val = Some(error)
            }
            group.return_immediately(())
          }
      }
    })
    primary() catch {
      error => if failure.val is None { failure.val = Some(error) }
    }
    completed.val = true
  }) catch {
    e => raise as_transport(e)
  }
  // core/async's version pauses here when the caller is being cancelled;
  // async-core has no pause, but check_cancellation delivers it.
  if @async-core.is_being_cancelled() {
    @async-core.check_cancellation()
  }
  if failure.val is Some(error) {
    raise error
  }
}

///|
pub extend WasiClock with @rt.Clock::{sleep, now_unix_ms}

///|
pub extend WasiTimer with @rt.Timer::{within}

///|
pub extend WasiGate with @rt.Gate::{acquire, release}

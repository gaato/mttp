///|
priv struct Waiter {
  mut waker : @driver.Waker?
  mut queued : Bool
}

///|
/// A FIFO counting gate driven by virtual tasks. Cancellation removes a
/// queued waiter; cancellation after handoff preserves the granted permit.
pub struct SimGate {
  priv driver : @driver.Driver
  priv size : Int32
  priv mut available : Int32
  priv queue : Array[Waiter]
}

///|
/// Creates a gate with `permits` slots. Negative capacity is treated as zero.
pub fn SimGate::new(driver : @driver.Driver, permits~ : Int32 = 1) -> SimGate {
  let size = permits.max(0)
  { driver, size, available: size, queue: [], }
}

///|
/// Reports permits immediately available without queueing.
pub fn SimGate::available(self : SimGate) -> Int32 {
  self.available
}

///|
/// Reports tasks currently queued for a permit.
pub fn SimGate::waiting(self : SimGate) -> Int32 {
  self.queue.length()
}

///|
/// Acquires a permit, suspending in FIFO order when capacity is exhausted.
pub impl @clock.Gate for SimGate with fn acquire(self) {
  if self.available > 0 {
    self.available -= 1
    return
  }
  let waiter : Waiter = { waker: None, queued: true, }
  self.queue.push(waiter)
  match self.driver.park_check_cancel(waker => waiter.waker = Some(waker)) {
    Woken => ()
    Cancelled =>
      if waiter.queued {
        waiter.queued = false
        for i, queued in self.queue {
          if physical_equal(queued, waiter) {
            let _ = self.queue.remove(i)
            break
          }
        }
        @driver.raise_cancellation()
      }
  }
}

///|
/// Hands a permit to the oldest waiter or restores one available slot.
/// Extra releases are capped at the gate's capacity.
pub impl @clock.Gate for SimGate with fn release(self) {
  if !self.queue.is_empty() {
    let waiter = self.queue.remove(0)
    waiter.queued = false
    if waiter.waker is Some(waker) {
      waker.wake()
    }
  } else if self.available < self.size {
    self.available += 1
  }
}

///|
/// Exposes admission and release on the concrete fake.
pub extend SimGate with @clock.Gate::{acquire, release}

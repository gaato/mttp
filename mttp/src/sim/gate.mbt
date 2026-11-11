///|
/// One task queued on a SimGate.
priv struct Waiter {
  mut waker : @driver.Waker?
  mut queued : Bool
}

///|
/// A FIFO counting Gate on a Driver. A waiter cancelled while queued leaves
/// the queue; one cancelled after the handoff keeps its slot.
pub struct SimGate {
  priv driver : @driver.Driver
  priv size : Int32
  priv mut available : Int32
  priv queue : Array[Waiter]
}

///|
/// Creates a gate with `permits` slots; a negative count means none.
pub fn SimGate::new(driver : @driver.Driver, permits~ : Int32 = 1) -> SimGate {
  let size = permits.max(0)
  { driver, size, available: size, queue: [], }
}

///|
/// The slots free now.
pub fn SimGate::available(self : SimGate) -> Int32 {
  self.available
}

///|
/// The tasks queued for a slot.
pub fn SimGate::waiting(self : SimGate) -> Int32 {
  self.queue.length()
}

///|
/// Takes a free slot, or queues in FIFO order until one is handed over.
pub impl @rt.Gate for SimGate with fn acquire(self) {
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
/// Hands the slot to the oldest waiter, or frees it; extra releases are
/// capped at the gate's capacity.
pub impl @rt.Gate for SimGate with fn release(self) {
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
/// The gate operations as methods of the double.
pub extend SimGate with @rt.Gate::{acquire, release}

///|
/// An admission gate backed by a cancellable async semaphore.
pub struct SemaphoreGate {
  priv semaphore : @semaphore.Semaphore
  priv mut held : Int32
}

///|
/// Creates a gate with one permit by default. Negative capacity is zero.
pub fn SemaphoreGate::new(permits~ : Int32 = 1) -> SemaphoreGate {
  {
    semaphore: @semaphore.Semaphore(
      permits.max(1),
      initial_value=permits.max(0),
    ),
    held: 0,
  }
}

///|
/// Explicit gate methods backed by the semaphore.
pub extend SemaphoreGate with @rt.Gate::{acquire, release}

///|
/// Waits for a permit, allowing runtime cancellation while queued.
pub impl @rt.Gate for SemaphoreGate with fn acquire(self) {
  self.semaphore.acquire()
  self.held += 1
}

///|
/// Returns one acquired permit.
pub impl @rt.Gate for SemaphoreGate with fn release(self) {
  if self.held > 0 {
    self.held -= 1
    self.semaphore.release()
  }
}

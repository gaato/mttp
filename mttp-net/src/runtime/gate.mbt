///|
/// An admission gate backed by a cancellable async semaphore.
pub struct SemaphoreGate {
  priv semaphore : @semaphore.Semaphore
}

///|
/// Creates a gate with one permit by default; nonpositive counts clamp to one.
pub fn SemaphoreGate::new(permits~ : Int32 = 1) -> SemaphoreGate {
  { semaphore: @semaphore.Semaphore(permits.max(1)), }
}

///|
/// Explicit gate methods backed by the semaphore.
pub extend SemaphoreGate with @clock.Gate::{acquire, release}

///|
/// Waits for a permit, allowing runtime cancellation while queued.
pub impl @clock.Gate for SemaphoreGate with fn acquire(self) {
  self.semaphore.acquire()
}

///|
/// Returns one acquired permit.
pub impl @clock.Gate for SemaphoreGate with fn release(self) {
  self.semaphore.release()
}

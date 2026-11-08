///|
/// A sticky one-shot notification on a Driver.
priv struct SimSignal {
  driver : @driver.Driver
  mut notified : Bool
  waiters : Array[@driver.Waker]
}

///|
impl @rt.Signal for SimSignal with fn wait(self) {
  while !self.notified {
    let mut registered : @driver.Waker? = None
    let outcome = self.driver.park_check_cancel(waker => {
      registered = Some(waker)
      self.waiters.push(waker)
    })
    if registered is Some(waker) {
      self.waiters.retain(other => !physical_equal(other, waker))
    }
    if outcome is Cancelled {
      @driver.raise_cancellation()
    }
  }
}

///|
impl @rt.Signal for SimSignal with fn notify(self) {
  self.notified = true
  let waiters = self.waiters.copy()
  self.waiters.clear()
  for waiter in waiters {
    waiter.wake()
  }
}

///|
/// Coordination whose only scheduler is a Driver: children are Driver tasks
/// and signals park on it.
pub struct SimCoordination {
  priv driver : @driver.Driver
}

///|
/// Creates a coordination on `driver`.
pub fn SimCoordination::new(driver : @driver.Driver) -> SimCoordination {
  { driver, }
}

///|
/// A new sticky signal on the same Driver.
pub impl @rt.Coordination for SimCoordination with fn signal(self) {
  SimSignal::{ driver: self.driver, notified: false, waiters: [], }
}

///|
/// Runs both children as Driver tasks and joins them on every exit; only
/// the cleanup itself is shielded from cancellation.
pub impl @rt.Coordination for SimCoordination with fn supervise(
  self,
  primary~,
  monitor~,
) {
  let failure : Ref[@http.TransportError?] = Ref(None)
  let completed = Ref(false)
  let work = self.driver.spawn(
    () => {
      primary() catch {
        error => if failure.val is None { failure.val = Some(error) }
      }
      completed.val = true
    },
    label="SimCoordination.primary",
  )
  let watching = self.driver.spawn(
    () => {
      monitor() catch {
        error =>
          if !completed.val {
            if failure.val is None {
              failure.val = Some(error)
            }
            work.cancel()
          }
      }
    },
    label="SimCoordination.monitor",
  )
  // Cancels the monitor (and the primary, when the caller is cancelled) and
  // waits for both to unwind, on every exit.
  defer self.driver.cancel_and_join([work, watching])
  // Neither child can fail: both catch every error they may raise.
  let _ = work.wait() catch { _ => false }
  if failure.val is Some(error) {
    raise error
  }
}

///|
/// The coordination operations as methods of the double.
pub extend SimCoordination with @rt.Coordination::{signal, supervise}

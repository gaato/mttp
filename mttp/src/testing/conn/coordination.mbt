///|
priv struct SimSignal {
  driver : @driver.Driver
  mut notified : Bool
  waiters : Array[@driver.Waker]
}

///|
impl @connection.Signal for SimSignal with fn wait(self) {
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
impl @connection.Signal for SimSignal with fn notify(self) {
  self.notified = true
  let waiters = self.waiters.copy()
  self.waiters.clear()
  for waiter in waiters {
    waiter.wake()
  }
}

///|
/// Coordination whose only scheduler is the supplied deterministic Driver.
pub struct SimCoordination {
  priv driver : @driver.Driver
}

///|
/// Uses driver for every child task and notification waiter.
pub fn SimCoordination::new(driver : @driver.Driver) -> SimCoordination {
  { driver, }
}

///|
/// Makes coordination operations available as methods.
pub extend SimCoordination with @connection.Coordination::{signal, supervise}

///|
/// Creates a sticky one-shot notification owned by the same Driver.
pub impl @connection.Coordination for SimCoordination with fn signal(self) {
  SimSignal::{ driver: self.driver, notified: false, waiters: [], }
}

///|
/// Joins both children on every exit, masking cancellation only during cleanup.
pub impl @connection.Coordination for SimCoordination with fn supervise(
  self,
  primary~,
  monitor~,
) {
  let failure : Ref[@model.TransportError?] = Ref(None)
  let completed = Ref(false)
  let work = self.driver.spawn(() => {
    primary() catch {
      error => if failure.val is None { failure.val = Some(error) }
    }
    completed.val = true
  })
  let watching = self.driver.spawn(() => {
    monitor() catch {
      error =>
        if !completed.val {
          if failure.val is None {
            failure.val = Some(error)
          }
          work.cancel()
        }
    }
  })
  defer self.driver.cancel_and_join([work, watching])
  ignore(work.wait()) catch {
    _ => ()
  }
  watching.cancel()
  ignore(watching.wait()) catch {
    _ => ()
  }
  if failure.val is Some(error) {
    raise error
  }
}

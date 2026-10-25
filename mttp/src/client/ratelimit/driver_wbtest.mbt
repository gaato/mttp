///|
fn spawn_now(d : @driver.Driver, f : async () -> Unit) -> @driver.Task raise {
  let task = d.spawn(f)
  let _ = d.step()
  task
}

///|
fn run_now(d : @driver.Driver, f : async () -> Unit) -> Unit raise {
  let task = spawn_now(d, f)
  assert_true(task.is_done())
}

///|
priv struct TestGate {
  driver : @driver.Driver
  mut free : Bool
  waiters : Array[(Bool) -> Unit]
  woken : Array[(Bool) -> Unit]
}

///|
fn TestGate::new(driver : @driver.Driver) -> TestGate {
  { driver, free: true, waiters: [], woken: [], }
}

///|
impl @clock.Gate for TestGate with fn acquire(self) {
  if self.free {
    self.free = false
    return
  }
  let admitted = Ref(false)
  self.driver.park(waker => {
    self.waiters.push(value => {
      admitted.val = value
      waker.wake()
    })
  })
  if !admitted.val {
    @driver.raise_cancellation()
  }
}

///|
impl @clock.Gate for TestGate with fn release(self) {
  if self.waiters.is_empty() {
    self.free = true
  } else {
    self.woken.push(self.waiters.remove(0))
  }
}

///|
fn TestGate::run_woken(self : TestGate) -> Unit raise {
  while !self.woken.is_empty() {
    self.woken.remove(0)(true)
    let _ = self.driver.step()
  }
}

///|
fn TestGate::cancel_oldest(self : TestGate) -> Unit raise {
  self.waiters.remove(0)(false)
  let _ = self.driver.step()
}

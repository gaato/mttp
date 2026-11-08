///|
priv struct Group {
  driver : @driver.Driver
  tasks : Array[@driver.Task]
}

///|
fn Group::spawn(
  self : Group,
  f : async () -> Unit,
  allow_failure~ : Bool = false,
) -> @driver.Task {
  let task = self.driver.spawn(f, allow_failure~)
  self.tasks.push(task)
  task
}

///|
fn Group::spawn_bg(self : Group, f : async () -> Unit) -> Unit {
  let _ = self.spawn(f)
}

///|
async fn with_group(driver : @driver.Driver, f : async (Group) -> Unit) -> Unit {
  let group = { driver, tasks: [], }
  f(group)
  for task in group.tasks {
    let _ = task.wait()
  }
}

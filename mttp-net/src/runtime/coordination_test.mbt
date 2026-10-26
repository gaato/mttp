///|
async test "runtime ports satisfy the shared coordination contract" {
  @testing.check_coordination_contract(@runtime.RuntimeCoordination::new(), suspend=() => {
    @async.pause()
  })
}

///|
async test "parent cancellation awaits both coordination children" {
  let coordination = @runtime.RuntimeCoordination::new()
  let entered = coordination.signal()
  let forever = coordination.signal()
  let cleaned = Ref(0)
  let completed = Ref(false)
  @async.with_task_group(group => {
    let task = group.spawn(allow_failure=true, () => {
      coordination.supervise(
        primary=() => {
          defer {
            cleaned.val += 1
          }
          entered.notify()
          forever.wait()
        },
        monitor=() => {
          defer {
            cleaned.val += 1
          }
          forever.wait()
        },
      )
      completed.val = true
    })
    entered.wait()
    @async.pause()
    task.cancel()
    task.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      error => raise error
    }
    assert_eq(cleaned.val, 2)
    assert_false(completed.val)
  })
}

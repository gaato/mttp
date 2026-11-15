///|
test "protected shutdown starts a fresh unwind round when its step budget is spent" {
  let max_steps = 4
  let d = Driver::new(max_steps~)
  let retried_exhausted_round = Ref(false)
  let finished_sleeps = Ref(0)
  d.run(() => {
    let _ = d.spawn(() => {
      d.protect(work=() => {
        // Leave enough callback budget to observe an illegal extra task step.
        // Without the guard, the buggy shutdown eventually exhausts both
        // budgets and spins on an already-due timer without running any task.
        d.pause()
        d.pause()
        for _ in 0..<12 {
          // step reports exhaustion after resuming a task. Tolerate that
          // extra step, but stop if shutdown resumes the same round again.
          if d.steps - d.budget_base > max_steps + 1 {
            retried_exhausted_round.val = true
            return
          }
          d.sleep(1)
          finished_sleeps.val += 1
        }
      })
    })
    d.pause()
  })
  assert_false(
    retried_exhausted_round.val,
    msg="shutdown retried with the same exhausted step budget",
  )
  assert_eq(finished_sleeps.val, 12)
  assert_eq((d.now(), d.live_tasks(), d.pending_timers()), (12L, 0, 0))
}

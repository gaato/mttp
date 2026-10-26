# gaato/mttp/testing/driver

A deterministic, single-threaded scheduler for MoonBit async code, with
virtual time. Tests in `gaato/mttp` are plain `test` blocks that drive async
code through a `Driver` or `run_sync`, so they run the same way on wasm-gc,
wasm, js and native without an async runtime.

> **Experimental.** The `Driver` is built on undocumented compiler
> intrinsics (`%async.run`, `%async.suspend`,
> `%async.raise_cancellation_signal` and `%async.capture_cancellation`). Its
> public API may break with any toolchain change, in any 0.1.x release.

## What it does

- `Driver::spawn` starts a task; tasks run one at a time, in the order they
  became ready (a FIFO queue), until they park or finish.
- `Driver::park` parks the current task until a one-shot `Waker` wakes it;
  `park_check_cancel` lets a gate see a cancellation before it unwinds.
- `Task::cancel` unwinds a task by the compiler's cancellation signal: its
  `defer` and `errdefer` blocks run, and no `catch` can intercept it.
- Time is virtual. `Driver::sleep` arms a timer; when no task is ready, `run`
  jumps to the earliest timer (auto-advance). `Driver::add_timer` runs a
  callback at a virtual instant.
- `Driver::run(main)` returns `main`'s value or raises its error, then
  cancels the tasks still alive and lets them unwind.
- `run_sync(f)` is `run` with auto-advance off: it refuses to wait, raising
  `Suspended` when every task is parked.

## Errors

Nothing in this package aborts. A `run` that cannot finish raises
`DriverError(kind~, detail~)`, whose `kind` may grow, so a `match` on it needs
a wildcard arm:

| Kind | When |
|---|---|
| `Deadlock(parked~)` | every task is parked and no timer is armed |
| `Suspended(parked~)` | every task is parked under `run_sync` (auto-advance off) |
| `NoQuiescence(steps~)` | one `run` took more than `max_steps` steps (default 100 000 000) |
| `UnwindIncomplete(live~)` | tasks kept spawning tasks through `max_unwind_rounds` (8) rounds of cancellation |
| `TaskFailed(label~, cause~)` | a task failed and no task waited on it |
| `MainCancelled` | the main task was cancelled |
| `Reentrant` | `run` or `step` was called from a task of the same driver |
| `NotInTask` | a task parked on a driver that is not running it, or `current()`, `current_task()` or an ambient helper was called outside a task |

## Example

```mbt check
///|
test "two sleepers on one virtual timeline" {
  let d = @driver.Driver::new()
  let log = []
  let elapsed = d.run(() => {
    let a = d.spawn(() => {
      d.sleep(20)
      log.push("a @\{d.now()}")
    })
    let b = d.spawn(() => {
      d.sleep(10)
      log.push("b @\{d.now()}")
    })
    let _ = a.wait()
    let _ = b.wait()
    d.now()
  })
  assert_eq(log, ["b @10", "a @20"])
  assert_eq(elapsed, 20L)
}
```

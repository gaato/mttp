# gaato/mttp_async/runtime

`gaato/mttp`'s runtime ports on `moonbitlang/core/async`, for native, wasm
(under moonrun) and js.

`AsyncClock`, `ClockTimer`, `SemaphoreGate` and `RuntimeCoordination`
implement the ports in `gaato/mttp/rt`. Their public APIs contain no core
runtime handles, so a package importing only this one needs no experimental
opt-in; a test that imports core/async itself lists that exact package.

The clock returns Unix epoch **milliseconds**. Nonpositive sleeps leave time
unchanged. A timer with a nonpositive budget returns false without invoking
its callback; expiry and parent cancellation join child cleanup.
Cancellation is a scheduler signal that passes `noraise` and ordinary
`catch` handlers.

```mbt check
///|
async test "a timer bounds a callback" {
  let timer = @runtime.ClockTimer::new()
  assert_true(timer.within(1000, () => ()))
  assert_false(timer.within(0, () => ()))
}
```

A gate defaults to one slot. Negative capacity is zero, queued callers are
FIFO, and extra releases cannot enlarge capacity. Install `defer gate.release()`
immediately after acquire. A cancelled queued waiter consumes no slot; a
waiter cancelled after handoff receives its slot before cancellation at its
next suspension, so it can install cleanup.

`RuntimeCoordination` creates sticky one-shot signals and supervises a primary
and monitor. Monitor success permits primary to finish; monitor failure
cancels primary; primary completion cancels monitor. The first delivered
outcome wins and every exit joins both children's cleanup.

`VirtualClock` is a clock for tests of time-dependent code on the real event
loop: pass it where a clock is expected (a Client, `AsyncBackend`, a
`ClockTimer`) and move time by hand instead of waiting. `VirtualClock(start_ms=...)`
starts at a chosen time. `advance` wakes current due sleepers at the new
timestamp; `advance_to_next` advances to the earliest registered deadline.
Neither infers runtime idleness. Use `settle(until=...)` to await an explicit
observation; its default 100,000 yields are bounded by `max_rounds` and an
unmet observation raises `NoQuiescence`. Cancellation removes sleeping
waiters. Negative advances leave time unchanged and timestamp arithmetic
saturates at Int64's maximum.

The generic `with_timeout_opt` helper preserves callback errors. For a
nonpositive duration it still starts the callback, admitting an immediate
result; `ClockTimer` has the stricter no-start rule above.

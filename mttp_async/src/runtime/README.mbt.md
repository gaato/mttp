# Runtime ports

`AsyncClock`, `ClockTimer`, `SemaphoreGate` and `RuntimeCoordination`
implement the ports in `gaato/http/rt` on `moonbitlang/core/async` for
native, wasm1 under moonrun, and JS. Their public APIs contain no core
runtime handles. A consumer importing only this package needs no experimental
opt-in; a test importing core/async itself lists that exact package.

The clock returns Unix epoch **milliseconds**, the unit core/async's source
uses for `now()`. Nonpositive sleeps leave time unchanged. A timer with a
nonpositive budget returns false without invoking its callback; expiry and
parent cancellation join child cleanup. Cancellation is a scheduler signal
that passes `noraise` and ordinary `catch` handlers.

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

`VirtualClock(start_ms=...)` preserves the reference constructor used by
Discord. `advance` wakes current due sleepers at the new timestamp;
`advance_to_next` advances to the earliest registered deadline. Neither
infers runtime idleness. Use `settle(until=...)` to await an explicit
observation; its default 100,000 yields are bounded by `max_rounds` and an
unmet observation raises `NoQuiescence`. Cancellation removes sleeping
waiters. Negative advances leave time unchanged and timestamp arithmetic
saturates at Int64's maximum.

The generic `with_timeout_opt` helper preserves callback errors. For a
nonpositive duration it still starts the callback, admitting an immediate
result; `ClockTimer` has the stricter no-start rule above.

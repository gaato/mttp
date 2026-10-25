# gaato/mttp-net

Runtime adapters for `gaato/mttp`, using `moonbitlang/async` on native,
moonrun wasm and JavaScript. This module is under development and unpublished.
The socket backend and server are not available yet.

## Install

Use the repository's `moon.work` workspace while the module is unpublished.
Registry installation will be available after the first release.

The `runtime` package provides a wall clock, a cancellable timer and a
semaphore gate implementing the runtime-free `gaato/mttp/clock` traits.

```mbt check
///|
test {
  let _ = @runtime.AsyncClock::new()
  let _ = @runtime.ClockTimer::new()
  let _ = @runtime.SemaphoreGate::new(permits=4)
}
```

`ClockTimer::within` cancels unfinished work when its clock expires and
returns false. A nonpositive budget returns false without invoking the
callback. Cancellation of the parent task propagates and unwinds the
callback. `SemaphoreGate` waits without blocking the runtime and clamps
nonpositive permit counts to one.

Programs using only request descriptions, codecs or deterministic tests
can depend on `gaato/mttp` without importing this module.

## License

Apache-2.0.

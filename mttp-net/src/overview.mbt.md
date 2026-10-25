# gaato/mttp-net

Runtime adapters for `gaato/mttp`, using `moonbitlang/async` on native,
moonrun wasm and JavaScript. This module is under development and unpublished.
The backend provides bounded HTTP/1 sockets and a JS fetch adapter. The server
adapter is not available yet.

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

`backend.AsyncBackend` implements one exchange on native, wasm and JS.
`backend.H1Backend` exposes the socket implementation on native/wasm. Both
compose with `mttp/client` policies. The `codings` package provides bounded
incremental gzip/deflate/br/zstd decoding independently of sockets.

## License

Apache-2.0.

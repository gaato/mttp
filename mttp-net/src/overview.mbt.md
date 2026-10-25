# gaato/mttp-net

Runtime adapters for `gaato/mttp`, using `moonbitlang/async` on native,
moonrun wasm and JavaScript. This module is under development and unpublished.
The backend provides bounded HTTP/1 sockets and a JS fetch adapter. The server
package serves HTTP/1 on native/wasm; fetch adapts handlers to Web Request and
Response on JavaScript, with host entry shims and tracked background work.

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

`VirtualClock(start_ms=...)` is a manually advanced test clock. `advance(ms)`
wakes sleepers already due at the new timestamp; it does not execute missed
periodic intervals retrospectively. `advance_to_next()` moves to the earliest
registered deadline. After either, use `settle(until=() => observed_state)`
before the next advance. The predicate is required: a fixed number of quiet
scheduler rounds cannot establish runtime idleness. An unmet observation
raises `NoQuiescence` after `max_rounds` (100,000 by default), and cancellation
still propagates. The runtime-free `mttp/testing/driver` owns its scheduler and
can instead provide exact scheduling and virtual-time control.

Programs using only request descriptions, codecs or deterministic tests
can depend on `gaato/mttp` without importing this module.

`backend.AsyncBackend` implements one exchange on native, wasm and JS.
`backend.H1Backend` exposes the socket implementation on native/wasm. Both
compose with `mttp/client` policies. The `codings` package provides bounded
incremental gzip/deflate/br/zstd decoding independently of sockets.

The socket backend reads response heads while uploading. A final response
stops an unfinished upload and closes its source; that connection is not
reused, even when the peer omitted `Connection: close`. Informational heads
do not stop the upload. The head idle timer starts after upload completes,
while write and total deadlines apply during upload. This is a request/response
adapter, not a full-duplex streaming tunnel: servers must not require further
request bytes after sending an early final response.

## License

Apache-2.0.

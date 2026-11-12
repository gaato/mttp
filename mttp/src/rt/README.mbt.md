# gaato/mttp/rt

The ports through which the connection engines and the client reach a runtime.

Each port is a trait; this package implements none of them, so code written
against it imports no event loop and builds on every target.

| Port | What it provides |
|---|---|
| `Clock` | Wall-clock time and delays |
| `Timer` | A time limit for a piece of work (`within`) |
| `Gate` | A counting, FIFO admission gate |
| `Conn` | An owned, full-duplex byte connection |
| `Dialer` | Opening connections and upgrading them to TLS |
| `Signal` | A sticky one-shot notification |
| `Coordination` | Structured concurrency: a primary task and its monitor |

`default_random` returns a sample in [0, 1) for jitter and boundaries; it is
not for secrets.

The implementations live elsewhere:

- [`gaato/mttp_async`](https://mooncakes.io/docs/gaato/mttp_async) implements
  them on `moonbitlang/core/async`: sockets, TLS, timers and task groups.
- `gaato/mttp/sim` implements them in memory on the deterministic driver, for
  tests on every target, and holds the contract checkers that both
  implementations pass.

The rules each side may rely on (sticky EOF, idempotent close, who owns a
connection after a TLS upgrade, how supervision ends, how cancellation
travels) are in the repository's
[CONTRACT.md](https://github.com/gaato/mttp/blob/main/CONTRACT.md).

## Example

Code takes the ports as trait objects, so a test can hand it a double:

```mbt check
///|
/// Waits `attempts` times, doubling the delay each time, and returns the
/// time spent.
async fn backoff(clock : &@rt.Clock, attempts : Int32) -> Int64 {
  let start = clock.now_unix_ms()
  for i = 0, delay = 100; i < attempts; i = i + 1, delay = delay * 2 {
    clock.sleep(delay)
  }
  clock.now_unix_ms() - start
}

///|
/// A clock whose sleeps move its time forward at once.
struct Instant {
  mut now : Int64
}

///|
impl @rt.Clock for Instant with fn sleep(self, ms) {
  if ms > 0 {
    self.now += ms.to_int64()
  }
}

///|
impl @rt.Clock for Instant with fn now_unix_ms(self) {
  self.now
}

///|
test "back off on a test clock" {
  let clock = Instant::{ now: 0, }
  assert_eq(@driver.run_sync(() => backoff(clock, 3)), 700L)
}
```

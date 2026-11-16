# gaato/mttp_core/rt

The ports through which the connection engines and the client reach a runtime.

Each port is a trait; this package implements none of them, so code written
against it imports no event loop and builds on every target.

| Port | What it provides |
|---|---|
| `Clock` | Wall-clock time and delays |
| `Timer` | A time limit for a piece of work (`within`) |
| `Gate` | A counting, FIFO admission gate |
| `Conn` | An owned, full-duplex byte connection |
| `Upgraded` | Take-once client connection hand-over and HTTP read-ahead |
| `Dialer` | Opening connections and upgrading them to TLS |
| `Signal` | A sticky one-shot notification |
| `Coordination` | Structured concurrency: a primary task and its monitor |

`default_random` returns a sample in [0, 1) for jitter and boundaries; it is
not for secrets.

An accepted HTTP 101 carries `upgraded`, whose `take_conn()` transfers the
connection and read-ahead once. Its owner closes the connection to release
the engine's slot. Closing the HTTP response body does not close it.
Discarding a response calls `close_unclaimed(response.attributes)` as well as
closing its body. Engines and Client use `Upgrades` to reclaim unclaimed
hand-overs on close, including responses arriving after close; taking or
discarding unregisters immediately, so the registry retains no completed
history. Claimed connections survive HTTP client closure.
Server handlers use `upgrade` for a callback receiving the connection,
read-ahead and a shutdown probe, after the HTTP reader is joined. The engine
retains admission until return and runs without HTTP deadlines; the listener's
drain deadline still applies. The application helper is `gaato/mttp/ws.upgrade`.

```mbt check
///|
test {
  assert_eq(@rt.upgraded.name(), "upgraded")
  assert_eq(@rt.upgrade.name(), "upgrade")
  let owner = @rt.Upgrades::new()
  let response = owner.track(@mttp_core.Response::new(200))
  @rt.close_unclaimed(response.attributes)
  owner.close()
}
```

The implementations live elsewhere:

- [`gaato/mttp`](https://mooncakes.io/docs/gaato/mttp) implements
  them on `moonbitlang/core/async`: sockets, TLS, timers and task groups.
- `gaato/mttp_core/sim` implements them in memory on the deterministic driver, for
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

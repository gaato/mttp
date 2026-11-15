# gaato/mttp_core/sim

In-memory doubles of the `gaato/mttp_core/rt` ports, and the contract checks every implementation passes.

The doubles run on the deterministic driver (`gaato/mttp_core/driver`). With them,
code written against the ports
(the connection engines, the mttp client, an SDK) is tested with plain `test`
blocks on wasm-gc, wasm, js and native, without sockets or an event loop.

The Driver-based doubles are test infrastructure. `WebSocketStub` also accepts
runtime Coordination for in-process upgrades without byte framing. The package imports
the experimental driver, so its Driver-taking constructors change when the
driver does; the package itself does not need the experimental opt-in.

## Doubles

| Double | Implements | What it is for |
|---|---|---|
| `FakeClock` | `Clock` | A sequential clock: each sleep adds its duration at once, and every duration is recorded |
| `SimClock`, `SimTimer` | `Clock`, `Timer` | The Driver's virtual time: concurrent sleeps overlap, deadlines cancel their work |
| `SimGate` | `Gate` | A FIFO gate whose queue can be inspected |
| `SimCoordination` | `Coordination` | Supervision and signals on the Driver |
| `pair` → `SimConn` | `Conn` | Two connected ends, with reads fragmented to `chunk_bytes` and a write-half `shutdown_write` |
| `ScriptedConn` (`ReadStep`) | `Conn` | Scripted reads (chunks, EOF, failures, waits) and recorded writes, for fault injection |
| `ScriptedDialer` | `Dialer` | Hands out prepared connections and records dials and TLS upgrades |
| `Feed` (`FeedStep`) | `BodyStream` | A scripted body with virtual waits, counting reads, closes and cancellations |
| `WebSocketStub::pair` | Two `&ws.Session`s | Complete messages in call order, retryable recv cancellation, and immediate in-process Close acknowledgement |

## Contract checks

`check_conn`, `check_coordination_contract`, `check_body_stream_contract` and
`check_backend_contract` check the rules of the repository's
[CONTRACT.md](https://github.com/gaato/mttp/blob/main/CONTRACT.md) on any
implementation:
the doubles here pass them in this package's tests, and gaato/mttp's
runtime adapters pass the same checks. Each raises `Failure` naming the first
rule it saw broken.

`check_splits` checks that an incremental parser gives the same result
however its input is split. The generators (`gen_chunks`, `gen_text`,
`gen_headers`, `gen_invalid_url`) feed property tests from the caller's
quickcheck seed; the sized ones clamp the requested size (128 text pieces, 32
header pairs).

## Schedule exploration

FIFO order shows one interleaving. `explore(scenario)` runs a scenario in FIFO
order and then under 32 seeded `@driver.Schedule`s, each taking orderings a
real runtime can also produce: bytes and EOF a `SimConn` delivers may reach
their reader after tasks that became ready later at the same virtual instant.
Any time advance ends that delay, and timers always fire in (deadline, arming)
order (CONTRACT.md, Driver rule 9). The scenario builds its Driver with the
schedule it is given:

```mbt nocheck
///|
test "a stopping server keeps its streamed response" {
  @sim.explore(schedule => {
    let h = Harness::new(schedule~) // calls @driver.Driver::new(schedule~)
    h.run(() => ...)
  })
}
```

A failing seed is replayed to make sure it is deterministic, and its choices
are shrunk with delta debugging. The failure names the seed and ends with the
call that replays the shrunk choices, to paste as a regression test:

```text
seed 3 of 32 fails:
...
its choices: [0, 1, 1, 0, 2]
ddmin shrank them to [0, 1] in 9 runs, which fail with:
...
replay: scenario(@driver.Schedule::replay([0, 1]))
```

A scenario that meets no decision point in FIFO order runs once. A double
whose completion the transport or the peer times wraps the wakes it makes in
`@driver.io_event`, as `SimConn` does.

## Example

```mbt check
///|
/// Reads until EOF and answers with what it read, in brackets: a stand-in
/// for code written against the ports.
async fn echo(conn : &@rt.Conn) -> Unit raise @mttp_core.TransportError {
  let reply = Buffer()
  reply.write_bytes(b"[")
  while conn.read(max_len=64) is Some(chunk) {
    reply.write_bytes(chunk)
  }
  reply.write_bytes(b"]")
  conn.write(reply.to_bytes())
  conn.close()
}

///|
test "talk to code over an in-memory pair" {
  let d = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(d)
  // One byte per read, so the code under test sees every split.
  let (client, server) = @sim.pair(coordination, chunk_bytes=1)
  let reply = d.run(() => {
    let task = d.spawn(() => echo(server))
    client.write(b"hello")
    client.shutdown_write()
    let reply = Buffer()
    while client.read(max_len=64) is Some(chunk) {
      reply.write_bytes(chunk)
    }
    let _ = task.wait()
    reply.to_bytes()
  })
  assert_eq(reply, b"[hello]")
  assert_eq(server.closes(), 1)
}

///|
test "the doubles pass the shared checks" {
  let d = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(d)
  let (left, right) = @sim.pair(coordination)
  d.run(() => {
    @sim.check_coordination_contract(coordination, suspend=() => d.pause())
    @sim.check_conn(left, right, coordination~, suspend=() => d.pause())
    @sim.check_body_stream_contract(() => @sim.Feed::bytes(d, [b"a"]), b"a")
  })
}
```

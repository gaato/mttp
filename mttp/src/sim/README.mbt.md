# gaato/http/sim

In-memory implementations of the `gaato/http/rt` ports, on the deterministic
driver (`gaato/http/driver`), and the contract checks that every
implementation of the ports passes. With them, code written against the ports
(the connection engines, the mttp client, an SDK) is tested with plain `test`
blocks on wasm-gc, wasm, js and native, without sockets or an event loop.

It is test infrastructure: production packages do not import it. It imports
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

## Contract checks

`check_conn`, `check_coordination_contract`, `check_body_stream_contract` and
`check_backend_contract` check the rules of the repository's `CONTRACT.md`
(https://github.com/gaato/mttp/blob/main/CONTRACT.md) on any implementation:
the doubles here pass them in this package's tests, and gaato/http-async's
runtime adapters pass the same checks. Each raises `Failure` naming the first
rule it saw broken.

`check_splits` checks that an incremental parser gives the same result
however its input is split. The generators (`gen_chunks`, `gen_text`,
`gen_headers`, `gen_invalid_url`) feed property tests from the caller's
quickcheck seed; the sized ones clamp the requested size (128 text pieces, 32
header pairs).

## Example

```mbt check
///|
/// Reads until EOF and answers with what it read, in brackets: a stand-in
/// for code written against the ports.
async fn echo(conn : &@rt.Conn) -> Unit raise @mttp.TransportError {
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

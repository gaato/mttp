# WebSocket sessions over portable ports

`gaato/mttp_core/ws` owns complete `Message::Text(String)` and
`Message::Binary(Bytes)` messages, `Session`, `CloseCode`, `CloseFrame`,
`WsError`, `WsLimits` and the per-message `Extension` port. HTTP upgrade
validation belongs to `ws/handshake`; engines hand a successful upgrade's
Conn and bytes read past its head to `session_over_conn`.

```mbt check
///|
test "receive a text message over injected ports" {
  let d = @driver.Driver::new()
  let conn = @sim.ScriptedConn::new([Chunk(b"\x81\x02hi")])
  let session = @ws.session_over_conn(
    conn,
    role=Client,
    pending=b"",
    clock=@sim.SimClock::new(d),
    timer=@sim.SimTimer::new(d),
    coordination=@sim.SimCoordination::new(d),
    entropy=_ => Some(b"abcd"), // deterministic key for this test only
    limits={ ..@ws.WsLimits::default(), ping_interval_ms: None, },
  )
  d.run(() => {
    assert_eq(session.recv(), @ws.Message::Text("hi"))
    session.abort()
  })
  assert_eq(conn.closes(), 1)
  assert_eq(d.live_tasks(), 0)
}
```

The constructor takes ownership of the Conn and pending bytes. Keep one
receiving task running: recv handles interleaved Ping/Pong and Close, validates
UTF-8 incrementally across fragments, assembles messages and drives keepalive.
Concurrent recv calls are refused. A cancelled recv retains partial input and
committed messages. Control writes use `Coordination.protect` and their own
send deadline; expiry closes Conn to wake a blocked writer. The caller must
inject a concurrent Clock/Timer and a Coordination sharing its scheduler.

send emits one frame per message, with FIFO serialization and a deadline
including queue wait. Cancelling a queued sender removes its ticket; cancelling
a partially written data frame fails the session and closes Conn. Client
frames request a fresh four-byte key from entropy for every frame: None or a
wrong length fails closed. Server frames do not call entropy. The callback
must use the runtime's secure randomness in production.

close is idempotent, sends one Close, waits for the peer's Close within its
deadline and closes Conn. abort closes immediately with local status 1006.
After Close begins only Close handling continues; Closed is permanent.
Invalid local Close payloads abort rather than raising from the noraise API.
Empty payloads are `NoStatus`; `CloseFrame.encode` never transmits code 1005.
Reserved codes fail with 1002, malformed UTF-8 with 1007, and size overflow
with 1009. Unknown CloseCode integers remain available for diagnostics;
sendable accepts defined 1000–1014 statuses except 1004–1006, plus 3000–4999,
and refuses 1015 and unassigned protocol ranges.

Defaults are 16 MiB per frame and wire/decoded message, 125 control bytes,
1024 consecutive empty frames, 30 s send wait and 5 s Close wait. Ping interval
is 30 s and any-byte answer wait 10 s. Either keepalive option being None or
nonpositive disables keepalive. Only the latest unsent Pong is retained.
The answer deadline starts when the Ping write completes; bytes received
during that write already count as life.

Extensions encode/decode complete messages; RSV1 marks only the first data
frame. decode receives the decoded byte bound and must enforce it while
producing output; the Session also checks its result. Controls bypass the
extension. No extension is enabled by default.

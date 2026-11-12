# gaato/mttp_async/server

An HTTP/1.1 listener for native and wasm (under moonrun).

`serve(handler, addr~)` binds TCP and serves each accepted connection with
`gaato/mttp_core/h1server.serve_conn`. `on_listen` receives the actual bound
address, including an ephemeral port chosen for `:0`. Requests carry an
absolute URL, the peer's address as `@mttp_core.remote_addr` and a scheduler for
work that outlives the response as `@mttp_core.background`. TLS termination
belongs to the deployment; use `codings.compress(handler)` when response
compression is wanted.

```mbt check
///|
async test "listener errors are distinct from connection errors" {
  try @server.serve(_ => @mttp_core.Response::new(204), addr="invalid") catch {
    @server.Bind(..) => ()
    error => raise error
  } noraise {
    _ => fail("invalid address accepted")
  }
}
```

`h1server.ServerLimits::default()` permits 256 accepted connections, 1 MiB
request bodies and 16 KiB heads. Admission waits **before accepting** a socket:
there is one acceptor/capacity waiter and no application queue of accepted
sockets or per-client waiting tasks. Further connections stay in the OS's
bounded listen backlog; overload and its ordering are controlled by the OS.
Five-second head/body budgets release slots from slow clients. See h1server
for body, drain, Expect, framing, half-close and handler-deadline behavior.

Cancelling `serve` stops acceptance and closes idle sockets. Active responses
and background jobs get `drain_ms` (ten seconds by default) to finish. Expiry,
including a zero budget, closes remaining sockets and cancels jobs; the call
joins their cleanup before propagating cancellation. A response counts as
active until its last byte is written, including the end of a chunked body,
and a connection becomes idle only between requests. Cleanup that shields
itself from cancellation can outlast the grace period.

An endless stream, such as server-sent events, would hold shutdown for the
whole `drain_ms`. A response that sets `@mttp_core.close_on_shutdown` to `true`
is closed when the server starts to shut down instead of being drained: the
stream is no longer pulled (a pull that waits is cancelled within a quarter
second), its `close` runs once, a chunked body ends with its last chunk and
the connection closes. Its clients reconnect, as event-stream clients do.
`endpoint.sse_out` and `sse_body_out` set it on the responses they build.

Such a stream may also stay silent for as long as it likes: the wait for its
next piece is not bounded by `body_timeout_ms`, so an event stream fed by a
slow upstream (an LLM, a queue) keeps its connection. Each write to the
client still has that deadline, so a client that stops reading is dropped.
The server sends no heartbeat of its own. Behind a reverse proxy, the proxy's
read timeout (nginx's `proxy_read_timeout`, 60 s by default) still closes an
idle stream; an app that needs to stay under it sends an event periodically.

The listener sets `SO_REUSEADDR`, as Go and Node do, so a restart (a systemd
`Restart=`, a deploy) binds again while the previous process's connections
are still in TIME-WAIT. On Linux it never lets a second listener take a port
that is being listened on. On macOS and the BSDs it also lets a bind to a
specific address coexist with an earlier wildcard bind of the same port.
core/async ignores the option on Windows, where TIME-WAIT never blocks a bind
and `SO_REUSEADDR` would allow another socket to take over the port.

Invalid limits raise `ListenError::Config(ServerConfigError)` before binding
or calling `on_listen`. Bind and accept failures raise `Bind` and `Accept`,
whose `detail` names the address and keeps the system's reason, such as
`could not bind 127.0.0.1:8080: @socket.TcpServer::new(): Address already in
use`; an address that does not parse says so and what is expected.
Connection errors go to `on_error` as `@mttp_core.TransportError`. Background
errors preserve `TransportError`; other background errors become `Network`
in phase `Unknown`, with application details omitted.

Schedule background work during handling. The listener tracks and joins it
even after the response ends; a scheduler kept past shutdown does nothing.
Applications own the number and duration of jobs they schedule.

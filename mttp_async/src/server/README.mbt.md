# HTTP/1 listener

`serve(handler, addr~)` binds TCP on native or wasm1 under moonrun and hands
accepted sockets to `gaato/mttp/h1server.serve_conn`. `on_listen` receives
the actual bound address, including an ephemeral port chosen for `:0`.
Requests carry an absolute URL, `http.remote_addr` and `http.background`.
TLS termination belongs to the deployment; use `codings.compress(handler)`
when response compression is wanted.

```mbt check
///|
async test "listener errors are distinct from connection errors" {
  try @server.serve(_ => @mttp.Response::new(204), addr="invalid") catch {
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
joins their cleanup before propagating cancellation. A response remains busy
through its wire writes, including chunked termination. Its private body lease
records closure; the next-request `stopping` checkpoint commits the idle
transition. This also covers HEAD and empty responses without exposing
runtime hooks in the portable engine. Cleanup that shields cancellation can
outlast the grace period, as with the underlying cooperative runtime.

An endless stream, such as server-sent events, would hold shutdown for the
whole `drain_ms`. A response that sets `@mttp.close_on_shutdown` to `true`
is closed when the server starts to shut down instead of being drained: the
stream is no longer pulled (a pull that waits is cancelled within a quarter
second), its `close` runs once, a chunked body ends with its last chunk and
the connection closes. Its clients reconnect, as event-stream clients do.
`endpoint.sse_out` sets it on the responses it builds.

Invalid limits raise `ListenError::Config(ServerConfigError)` before binding
or calling `on_listen`. Bind and accept failures raise `Bind` and `Accept`.
Connection errors go to `on_error` as `http.TransportError`. Background errors
preserve `TransportError`; other background errors become `Network` in phase
`Unknown`, with application details omitted.
Schedule background work during handling. The listener tracks and joins it
even after the response ends; retained schedulers do nothing after shutdown.
Applications own the number and duration of jobs they schedule.

The listener's immutable lifecycle decisions live in
`mttp_async/internal/control`, with separate resource tables in this adapter.
MoonBit's module visibility prevents importing `http/internal/control` here;
the listener uses the same transition rules and snapshot tests locally.

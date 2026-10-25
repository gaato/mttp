# HTTP/1 server

`serve` runs a plain TCP HTTP/1.0 and HTTP/1.1 listener on native and wasm.
It accepts the runtime-free `model.Handler`, including `Router::handler()`.
TLS termination belongs to the surrounding deployment; this API does not
pretend to provide a TLS listener.

```mbt nocheck
@server.serve(
  request => @model.Response::new(200, body=Bytes(b"hello")),
  addr="127.0.0.1:8080",
  compression=true,
)
```

The body budget starts with its first read and covers the whole body, including
gaps between pulls; receiving another chunk does not restart it. Response writes
use that duration as a per-write budget.

Configuration is checked before binding. Defaults are 1 MiB request bodies,
16 KiB heads, 256 connections, five-second header and body budgets, 64 KiB of
unread-body draining and ten seconds of graceful shutdown. The header budget
covers the entire head; body reads and bounded writes each receive an idle
budget. An optional handler deadline returns 504. Limits apply even when a
handler catches an oversized or malformed body read. Headers, duplicate
Set-Cookie fields and chunk framing are handled by `mttp/h1`.

The request URL is absolute, with authority from Host for origin-form targets.
OPTIONS `*` is represented as `/*` under that authority. CONNECT returns 501;
protocol upgrades are not implemented. `remote_addr` is set from the accepted
peer. `background` schedules application work in the server group, which may
outlive the response but shares shutdown's grace budget. Call the scheduling
function during request handling; retaining it after the server stops does not
start new work. Application-created background tasks have no implicit count
limit, so applications must bound how much work they schedule.

`Expect: 100-continue` is answered only when the handler first reads the body.
A head or authentication refusal can send its final response without asking
for an upload. A security input that authenticates raw bytes necessarily reads
those bytes first. Unread bodies are drained only within the configured budget;
otherwise the connection closes. Once that budget is exhausted, a chunked body
whose terminating framing has not arrived may be closed conservatively.

Cancellation stops acceptance, closes idle connections and lets active
exchanges and background tasks finish within `drain_ms`; expiry cancels them
and closes their sockets. As with the runtime, application code that shields
itself from cancellation can delay shutdown beyond that budget.

After the request body finishes, one read-ahead of at most 64 KiB detects
read-side EOF or socket failure and cancels a suspended exchange. This treats
a peer's write-half close as a disconnect. Detection pauses when pipelined
bytes already occupy the read-ahead buffer, so monitoring cannot accumulate
unlimited queued requests. Response producers and request readers close when
their exchange is cancelled.

Compression is opt-in. Negotiation selects gzip, deflate or Brotli, adds Vary,
removes obsolete length/digest fields and weakens strong ETags. Existing content
encodings, ranges, bodyless statuses and `Cache-Control: no-transform` remain
application-owned. A request refusing every available encoding and identity
gets 406 when compression is applicable. Live output is flushed incrementally.

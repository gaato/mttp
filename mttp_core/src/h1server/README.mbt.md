# gaato/mttp_core/h1server

An HTTP/1.1 server connection engine over the `gaato/mttp_core/rt` ports.
`serve_conn` serves the requests of one accepted connection with an
`@mttp_core.Handler`. Every head, chunk-size line and trailer section is read
through the bounded `gaato/mttp_core/h1` codec. Head and body operations have
deadlines; a handler deadline is optional.

> [`gaato/mttp_async`](https://mooncakes.io/docs/gaato/mttp_async) wires
> this engine to sockets, TLS and an event loop; most applications use that
> instead.

## Serving a connection

The engine needs a connection and the ports only. Here the in-memory doubles
of `gaato/mttp_core/sim` stand in for a socket, so the example runs on every
target:

```mbt check
///|
test "serve a request" {
  let driver = @driver.Driver::new()
  let coordination = @sim.SimCoordination::new(driver)
  let (client, server) = @sim.pair(coordination)
  let errors = []
  driver.run(() => {
    let task = driver.spawn(() => {
      @h1server.serve_conn(
        server,
        request => {
          let greeting = "hello from " + request.url
          @mttp_core.Response::new(
            200,
            body=Bytes(@mttp_core.encode_utf8(greeting)),
          )
        },
        clock=@sim.SimClock::new(driver),
        timer=@sim.SimTimer::new(driver),
        coordination~,
        scheme="https",
        on_error=error => errors.push(error),
      )
    })
    client.write(b"GET /docs HTTP/1.1\r\nHost: example.test\r\n\r\n")
    // A head the codec refuses is answered and ends the connection.
    client.write(b"GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n")
    let out = Buffer()
    while client.read(max_len=4096) is Some(bytes) {
      out.write_bytes(bytes)
    }
    let text = @utf8.decode(out.to_bytes())
    assert_true(text.has_prefix("HTTP/1.1 200 OK\r\n"))
    assert_true(text.contains("hello from https://example.test/docs"))
    assert_true(text.contains("HTTP/1.1 400 Bad Request\r\n"))
    ignore(task.wait())
  })
  assert_eq(server.closes(), 1)
  assert_eq(errors.length(), 1)
}
```

## What it guarantees

- **Ownership.** `serve_conn` owns its connection from the start and closes
  it on every exit, cancellation and refused settings included.
- **Strict framing.** Request smuggling (Content-Length with
  Transfer-Encoding, a duplicate or invalid Content-Length, Transfer-Encoding
  on HTTP/1.0) is answered with 400 and the connection closes, so no byte
  after the head is read as another request. Other heads are refused with
  431 (past the head limits), 400 (malformed, a missing or duplicate `Host`),
  501 (CONNECT, a transfer coding other than `chunked`), 505 (an HTTP version
  other than 1.x) or 417 (an expectation other than `100-continue`).
- **Bounded input.** Heads within `max_header_bytes` and 100 fields, chunk
  lines within 4 KiB, trailers within 16 KiB and 100 fields, bodies within
  `max_body_bytes` (413), reads of at most 64 KiB, and at most 64 KiB of raw
  read-ahead while a body is unclaimed. Its first pull cancels and joins the
  monitor's read before taking over, consuming buffered bytes first; there
  is always one connection reader. After the body completes the monitor
  makes at most one read ahead for the next head. A body left unread is drained
  up to `drain_max_bytes`, otherwise the connection closes.
- **Deadlines.** `header_timeout_ms` from the end of one exchange to the end
  of the next head (408 once a byte arrived, a silent close before),
  `body_timeout_ms` for a whole request body (408) and for each write and
  each read of a streamed response, `handler_timeout_ms` for the handler
  (504). A timeout before the response head is 408 only when a request-body
  pull was in progress or already failed; an independent response producer
  timing out becomes 500 and reaches `on_error`, even with an unread body.
  A response stream that pauses longer than `body_timeout_ms` ends its
  connection, unless the response sets `@mttp_core.close_on_shutdown` (every
  event stream from `endpoint.sse_out` does): such a stream may stay silent
  for any time, since shutdown ends it, while each write to the client
  keeps the deadline, so a client that stops reading is still dropped.
  Other long-polling handlers raise the limit.
- **Failures.** Before a response head is written, a body failure replaces
  the handler's response with its own status, even when the handler caught
  it. An invalid response or a producer failure before the head becomes
  500; failures after the head close the connection. Failures reach `on_error` as an
  `@mttp_core.TransportError`. `@mttp_core.Handler` is `noraise`; applications handle
  their own exceptions before returning a response.
- **Peers.** `100 Continue` is sent when the handler first reads the body. A
  read failure while the handler runs cancels it, including while its body
  is unclaimed and the read-ahead buffer has room. Once that buffer fills,
  monitoring stops until the handler reads; body pulls and a configured
  handler deadline must provide progress. The handler deadline defaults to
  `None`, so a handler that never pulls or returns can still wait indefinitely
  at this bound. Read-ahead neither sends `100 Continue` nor starts the lazy
  body deadline. EOF does not cancel the handler, because the peer may have
  closed only its sending half. HTTP/1.0 keeps a connection
  only when it asks for `keep-alive` and the response has a length; it is
  never sent a chunked body.
- **Raw bytes.** The engine adds the framing fields and `Connection` and
  nothing else; content codings are a handler wrapper's job.
- **Listener boundary.** The caller accepts connections and owns the
  background scheduler. `max_connections` (256) and shutdown `drain_ms`
  (10 seconds) are validated settings for that adapter, which enforces them
  across connections. `serve_conn` checks `stopping` between requests and
  before writing a response to send `Connection: close`. A streamed
  response marked `@mttp_core.close_on_shutdown` is cut once `stopping` holds,
  also while its producer waits (`stopping` is asked every 250 ms then): the
  body is closed, a chunked body ends with its last chunk, a body with a
  Content-Length is left short, and the connection closes. Cancelling
  `serve_conn` unwinds and closes its connection. It does not bind, accept or manage
  detached jobs.

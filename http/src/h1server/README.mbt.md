# gaato/http/h1server

An HTTP/1.1 server connection engine over the `gaato/http/rt` ports.
`serve_conn` serves the requests of one accepted connection with an
`@http.Handler`. Every head, chunk-size line and trailer section is read
through the bounded `gaato/http/h1` codec. Head and body operations have
deadlines; a handler deadline is optional.

> **Experimental.** The engine's settings and its reporting may still
> change; an importer lists it in
> `options("allow-experimental-packages": ["gaato/http/h1server"])`.
> [`gaato/http-async`](https://mooncakes.io/docs/gaato/http-async) wires it
> to sockets, TLS and an event loop; most applications use that instead.

## Serving a connection

The engine needs a connection and the ports only. Here the in-memory doubles
of `gaato/http/sim` stand in for a socket, so the example runs on every
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
          @http.Response::new(200, body=Bytes(@http.encode_utf8(greeting)))
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
  `max_body_bytes` (413), reads of at most 64 KiB, and at most one read ahead
  of the request being served. A body the handler leaves unread is drained
  up to `drain_max_bytes`, otherwise the connection closes.
- **Deadlines.** `header_timeout_ms` from the end of one exchange to the end
  of the next head (408 once a byte arrived, a silent close before),
  `body_timeout_ms` for a whole request body (408) and for each write and
  each read of a streamed response, `handler_timeout_ms` for the handler
  (504). A response stream that pauses longer than `body_timeout_ms` ends
  its connection, so long-polling handlers raise that limit.
- **Failures.** Before a response head is written, a body failure replaces
  the handler's response with its own status, even when the handler caught
  it. An invalid response or a producer failure before the head becomes
  500; failures after the head close the connection. Failures reach `on_error` as an
  `@http.TransportError`. `@http.Handler` is `noraise`; applications handle
  their own exceptions before returning a response.
- **Peers.** `100 Continue` is sent when the handler first reads the body. A
  read failure while the handler runs cancels it; EOF does not, because the
  peer may have closed only its sending half. HTTP/1.0 keeps a connection
  only when it asks for `keep-alive` and the response has a length; it is
  never sent a chunked body.
- **Raw bytes.** The engine adds the framing fields and `Connection` and
  nothing else; content codings are a handler wrapper's job.
- **Listener boundary.** The caller accepts connections and owns the
  background scheduler. `max_connections` (256) and shutdown `drain_ms`
  (10 seconds) are validated settings for that adapter, which enforces them
  across connections. `serve_conn` checks `stopping` between requests and
  before writing a response to send `Connection: close`; cancelling it
  unwinds and closes its connection. It does not bind, accept or manage
  detached jobs.

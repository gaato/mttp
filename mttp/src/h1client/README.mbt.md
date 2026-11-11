# gaato/http/h1client

An HTTP/1.1 client connection engine over the `gaato/http/rt` ports. It
keeps a pool of connections per origin, admits at most the configured number
of active exchanges, reads every response head, chunk-size line and trailer
section through the bounded `gaato/http/h1` codec, and puts each phase of an
exchange under a deadline. `Client` implements `@mttp.Backend`, so a policy
layer (retries, redirects, cookies, content decoding) wraps it without
knowing it.

> [`gaato/mttp_async`](https://mooncakes.io/docs/gaato/mttp_async) wires
> this engine to sockets, TLS and an event loop; most applications use that
> instead.

## Sending a request

The engine needs the ports only: a `Dialer`, a `Clock`, a `Timer` and a
`Coordination`. Here the in-memory doubles of `gaato/http/sim` stand in for
a network, so the example runs on every target:

```mbt check
///|
test "send a request and read the response" {
  let driver = @driver.Driver::new()
  let conn = @sim.ScriptedConn::new([
    Chunk(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"),
  ])
  let client = @h1client.Client::new(
    dialer=@sim.ScriptedDialer::new([conn]),
    clock=@sim.SimClock::new(driver),
    timer=@sim.SimTimer::new(driver),
    coordination=@sim.SimCoordination::new(driver),
    config={
      ..@h1client.ClientConfig::default(),
      connect_timeout_ms: Some(10000),
    },
  )
  driver.run(() => {
    let response = client.send(@mttp.Request::get("http://example.test/"), {
      timeout_ms: Some(30000),
      body: Exchange(max_bytes=1 << 20),
    })
    assert_eq(response.status, 200)
    guard response.body is Stream(body) else { fail("expected a body") }
    assert_eq(@mttp.read_bounded(body.take(), 1 << 20), b"hello")
    // Read to its end, the connection is parked for the next request.
    assert_eq(client.idle_connections(), 1)
    client.close()
  })
  assert_eq(conn.closes(), 1)
}
```

## What it guarantees

- **Validation first.** An invalid URL, method, header or framing, and
  `SendOptions` that `validate` refuses, fail with `Invalid` (or
  `Timeout(ms)` for a nonpositive deadline) in phase Pool before any dial.
- **Raw bytes.** The engine adds a `Host` field and the framing fields and
  nothing else: no `Accept-Encoding`, no decoding, no redirects, no retries.
- **Bounded input.** Heads, chunk-size lines and trailers are read within
  `ClientConfig.head_limits`. With `Exchange(max_bytes)` at most `max_bytes`
  body bytes (and `ClientConfig.max_body_bytes`) are read from the wire; a
  streamed body is bounded by the configured ceiling. The read that would
  cross the bound raises `TooLarge(limit)` in phase Body and discards the
  connection.
- **Deadlines.** `SendOptions.timeout_ms` covers the head and, with
  `Exchange`, the whole body; with `Stream(idle_ms)`, each body read waits at
  most `idle_ms`. The `ClientConfig` limits bound each phase on top. A
  `Timeout(ms)` names the limit that ran out and the phase it ran out in.
- **Uploads.** A stream body is taken and its first piece read before
  anything is written, so a stream that fails or lies about being empty
  sends nothing; it is closed on every exit. A response that arrives during
  an upload ends the upload, and that connection is not reused.
- **Reuse.** A connection is parked only after a complete, keep-alive
  exchange with no unread bytes, and is handed only to a request with the
  same origin and User-Agent. A request on a reused connection that fails
  before any response byte arrived is resent once on a fresh connection, if
  its body is replayable and it is idempotent (`@mttp.is_idempotent`); such
  a response carries the `stale_resend` attribute.
- **Proxies.** `ClientConfig.proxy` names an HTTP proxy per scheme and a
  `NO_PROXY` list, as data: `ProxyConfig::from_env(lookup)` reads the usual
  environment variables once, through a lookup the caller passes, and the
  client never reads the environment itself. `http://` requests are
  forwarded with an absolute target; `https://` requests go through a
  `CONNECT` tunnel with TLS end to end. A request's own
  `Proxy-Authorization` is never sent; a proxy's credentials (from its
  URL) go to that proxy only. Connections through different proxies, or
  none, are pooled apart.
- **Ownership.** A response body owns its connection and slot until it is
  read to its end or closed. Cancelling a send or a read closes what it
  owns and propagates unchanged.

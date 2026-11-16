# gaato/mttp/ws

`upgrade` checks a handler's WebSocket handshake and returns its 400/403/426
refusal or a 101 carrying `@rt.upgrade`. The handler receives a server-role
session after the HTTP reader is joined. SameOrigin is the default; the first
offered supported subprotocol wins. No extensions are negotiated.

```mbt check
///|
test "ordinary requests are refused" {
  let response = @ws.upgrade(@mttp_core.Request::get("http://example.test/"), handler=_ => {
    ()
  })
  assert_eq(response.status, 400)
}
```

Keep a receiving task running to service Ping and Close. On server shutdown,
the helper sends Close 1001 within a 250 ms polling interval, waits at most
`WsLimits.close_timeout_ms`, and aborts the connection. The listener retains
its admission slot until the handler ends and enforces its overall `drain_ms`.

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

`connect` opens a `ws://` or `wss://` session over the default backend, or a
caller-owned Backend. TLS uses the backend's trust and dialer. Environment
HTTP proxies use CONNECT for both schemes. Redirects are disabled; a 3xx is
a handshake error. There is no reconnect policy. Extensions are reserved.
On JS, connect uses the host's WebSocket message API. Workers, Deno and Bun
also support upgrade through fetch_handler; Node fetch returns 501. The
[host support matrix](https://github.com/gaato/mttp/blob/main/mttp/hosts/README.md#websockets) describes custom
headers, bounded inbound queues and the controls that hosts keep private.

One receiving task drives messages and answers Ping and Close. Close or
abort every session to release its connection slot. The caller owns a
supplied backend; the default backend needs no separate cleanup.

```mbt check
///|
async fn echo(url : String) -> String raise @ws.WsError {
  let session = @ws.connect(url)
  defer session.abort()
  session.send(Text("hello"))
  match session.recv() {
    Text(text) => text
    Binary(_) => "binary"
  }
}

///|
test {
  let _ : async (String) -> String raise @ws.WsError = echo
}
```

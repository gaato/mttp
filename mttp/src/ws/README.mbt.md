# gaato/mttp/ws

`connector(base_url~, backend?)` adapts `connect` for a portable typed
`WsEndpoint`. Pass a Router backend for in-process calls; its real byte codec
runs on all targets, including JS. A supplied backend remains caller-owned.
Socket and fetch servers accept `WsEndpoint.serve(...)` in the usual Router;
their adapters supply the Session after the handshake succeeds.

```mbt check
///|
test "typed connector definition" {
  let chat = @endpoint.ws_endpoint()
    .get("/chat")
    .messages(incoming=@endpoint.ws_text(), outgoing=@endpoint.ws_text())
  let connect = @ws.connector(base_url="ws://example.test")
  let _ : async () -> Result[
    @endpoint.TypedSession[String, String],
    @endpoint.WsConnectFailure,
  ] = () => chat.connect(connect, (), ())
}
```

`upgrade` checks a handler's WebSocket handshake and returns its 400/403/426
refusal or a 101 carrying `@rt.upgrade`. The handler receives a server-role
session after the HTTP reader is joined. SameOrigin is the default; the first
offered supported subprotocol wins. Compression is off by default.

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
a handshake error. There is no reconnect policy.
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

Pass `compression=Compression::new()` to `connect` or `upgrade` to opt in
to [permessage-deflate (RFC 7692)](https://www.rfc-editor.org/rfc/rfc7692.html).
The default requests no context takeover in both directions. Set either
`server_no_context_takeover=false` or `client_no_context_takeover=false` on
the constructor to allow takeover for that direction. Each connection owns
its encoder and at most 32 KiB of decoded history. Controls stay uncompressed;
RSV1 marks only the first data fragment. Inflated bytes have their own
`max_message_bytes` bound, checked during decoding; overflow sends Close 1009.
If transformed output exceeds a wire limit, or its send is cancelled, the
session aborts so compression history cannot refer to an unsent message.

BFINAL restarts are limited to eight per message (Close 1009 beyond that
resource limit). Decoder storage is reused; `reset(dictionary=...)` restores
the last 32 KiB across restarts. The RFC four-byte tail is decoded separately:
every byte must be consumed, it must produce no output, and decoding must end
at a block boundary. Tail-generated data and incomplete headers are Close 1002.

| Parameter | Server receiving an offer | Client receiving a response |
|---|---|---|
| `server_no_context_takeover` | Honour if present; may add it | Required if requested; allowed unsolicited |
| `client_no_context_takeover` | May add it; echo hints | Always supported, even unsolicited; absence permits takeover |
| `server_max_window_bits` | Accept 15 and echo it; decline 8–14 | Accept 8–15 (decoder has 32 KiB) |
| `client_max_window_bits` | Bare or 8–15 accepted as hints; omit response parameter | Accept only 15; smaller values constrain our fixed-window encoder |
| Unknown, duplicate, invalid value | Decline this offer and try the next | Fail handshake |

Window values are decimal 8–15 without leading zeroes; flags have no value.
Only the offer may have bare `client_max_window_bits`. The client always
offers it, so a response with value 15 is allowed. If the server declines
compression, the connection continues uncompressed. The legacy `extensions`
argument remains unsupported; use `compression` for this implementation.

```mbt check
///|
test "compression options are explicit" {
  let _ = @ws.Compression::new()
  let _ = @ws.Compression::new(client_no_context_takeover=false)
  let _ = @ws.upgrade(
    @mttp_core.Request::get("http://example.test/"),
    compression=@ws.Compression::new(),
    handler=_ => (),
  )
}
```

On JS, `compression` has no effect: the host owns negotiation and inflation.
The option does not enable a host feature or disable its defaults. See the
host matrix for Node, Deno, Bun, browsers and Workers. The application queue
bound applies after the host has allocated and decompressed each message.

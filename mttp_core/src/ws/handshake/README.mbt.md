# WebSocket opening handshake

`gaato/mttp_core/ws/handshake` builds and validates RFC 6455 opening-handshake
values without opening a connection. Entropy, HTTP transmission, and the
post-101 connection hand-over belong to the caller and the HTTP engines.

```mbt check
///|
test {
  let key = @handshake.new_key(n => Some(Bytes::make(n, b'\x2a')))
  let request = @handshake.client_request(
    "wss://example.com/chat",
    key~,
    subprotocols=["chat"],
    origin="https://example.com",
  )
  let offer = @handshake.check_client_request(request, subprotocols=["chat"])
  let response = offer.accept(subprotocol="chat")
  let accepted = @handshake.check_server_response(
    response,
    key~,
    offered_subprotocols=["chat"],
    offered_extensions=[],
  )
  assert_eq(accepted.subprotocol, Some("chat"))
}
```

The default server origin policy is `SameOrigin`. A missing `Origin` is
accepted because non-browser clients normally omit it. `Allow` compares only
scheme, host, and effective port; `Any` disables origin filtering.

Extension negotiation here is syntax-only. `Extension` preserves an element's
name and ordered parameters, including bare parameters and decoded quoted
values. A later negotiation stage must interpret extension-specific rules such
as permessage-deflate parameters before constructing a session.


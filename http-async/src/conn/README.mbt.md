# TCP and TLS connections

`TcpDialer` implements `gaato/http/rt.Dialer` on core/async for native and
wasm1 under moonrun. It connects with TCP and can upgrade **any** `&Conn` to
TLS, including a connection handed off by an HTTP CONNECT tunnel. Each TLS
bridge owns its binary reader/writer controllers so nested connections do
not share buffering state. One reader and writer may operate concurrently;
socket reads and writes use slices of at most 64 KiB.

```mbt check
///|
test "choose TLS trust without exposing a runtime type" {
  let _ = @conn.TcpDialer::new()
  let _ = @conn.TcpDialer::new(trust=PemFile("roots.pem"))
  assert_eq(@http_async.Trust::System, @http_async.Trust::System)
}
```

`Trust` is defined in the cross-target `gaato/http-async` root package.
`Trust::System` is the default and uses system certificate roots.
`Trust::Insecure` disables verification. `Trust::PemFile(path)` trusts exactly
the certificates in that PEM file, **replacing** system roots, matching core's
`CustomPemFile`. To trust system roots plus a private CA, pass a PEM bundle
containing both. There is no separate portable additive mode.

A successful TLS upgrade takes ownership of its inner connection. A failed
or cancelled handshake leaves it owned by the caller, which must close it.
Close is idempotent and cancels pending directional I/O before the operation
returns. Cancelling a read or write joins that direction's cleanup before
another operation can use it. EOF permanently ends only the read half.

Dial and TLS-handshake failures are `TransportError(Connect, Dial)`; subsequent
I/O failures become `Network, Unknown`, preserving an existing TransportError.
Writes after explicit close raise `Closed, Unknown`. The engines attach their
current exchange phase when they interpret these connection failures.

Write-half shutdown and ALPN negotiation are unavailable through this adapter.
The loopback tests use an ephemeral listener on `127.0.0.1:0`; their test-only
certificate and key authenticate localhost and are never used in production.

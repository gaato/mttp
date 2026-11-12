# gaato/mttp_async/conn

TCP and TLS connections for native and wasm (under moonrun).

`TcpDialer` implements `gaato/mttp/rt.Dialer`. It connects with TCP and can
upgrade **any** `&Conn` to TLS, including a connection handed off by an HTTP
CONNECT tunnel. One reader and one writer may use a connection at the same
time; socket reads and writes use slices of at most 64 KiB.

```mbt check
///|
test "choose TLS trust without exposing a runtime type" {
  let _ = @conn.TcpDialer::new()
  let _ = @conn.TcpDialer::new(trust=PemFile("roots.pem"))
  assert_eq(@trust.Trust::System, @trust.Trust::System)
}
```

`Trust` is defined in `gaato/mttp_async/trust` and re-exported by the root
package as `@mttp_async.Trust`. `Trust::System` is the default and uses
system certificate roots. `Trust::Insecure` disables verification.
`Trust::PemFile(path)` trusts exactly the certificates in that PEM file,
**replacing** system roots. To trust system roots plus a private CA, pass a
PEM bundle containing both.

A successful TLS upgrade takes ownership of its inner connection. A failed
or cancelled handshake leaves it owned by the caller, which must close it.
Close is idempotent and cancels pending reads and writes before it returns.
EOF ends only the read half.

Dial and TLS-handshake failures are `TransportError(Connect, Dial)`; later
I/O failures become `Network, Unknown`, keeping an existing TransportError.
Writes after an explicit close raise `Closed, Unknown`. The HTTP engines
replace `Unknown` with the phase of the exchange they were in.

Shutting down only the write half and ALPN negotiation are not available.

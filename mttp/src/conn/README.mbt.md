# gaato/mttp/conn

TCP and TLS connections for native and wasm (under moonrun).

`TcpDialer` implements `gaato/mttp_core/rt.Dialer`. It connects with TCP and can
upgrade **any** `&Conn` to TLS, including a connection handed off by an HTTP
CONNECT tunnel. One reader and one writer may use a connection at the same
time; socket reads and writes use slices of at most 64 KiB.

```mbt check
///|
test "choose TLS trust without exposing a runtime type" {
  let _ = @conn.TcpDialer::new()
  let _ = @conn.TcpDialer::new(trust=PemFile("roots.pem"))
  let _ = @conn.TcpDialer::new(refuse_internal=true)
  assert_eq(@trust.Trust::System, @trust.Trust::System)
}
```

`refuse_internal` is opt-in (default `false`). The dialer resolves once,
rejects internal and selected special-purpose destinations with
`TransportError(Invalid, Dial)` and a `refuse_internal: resolved address`
detail, then connects to that exact `Addr`. There is no second resolution;
TLS still uses the original hostname for SNI and certificate verification.
Using this dialer in an h1 client checks every new dial, including redirect
hops. Existing pooled connections were checked when opened.

The conservative policy follows [RFC 6890](https://www.rfc-editor.org/rfc/rfc6890)
and the [IANA IPv4](https://www.iana.org/assignments/iana-ipv4-special-registry/)
and [IPv6](https://www.iana.org/assignments/iana-ipv6-special-registry/)
registries (2026-11-16): IPv4 `0/8`, `10/8`, `100.64/10`, `127/8`,
`169.254/16`, `172.16/12`, `192.0.0/24`, `192.0.2/24`, `192.88.99/24`,
`192.168/16`, `198.18/15`, `198.51.100/24`, `203.0.113/24`, multicast
`224/4` and reserved `240/4`. IPv6 rejects unspecified, loopback and the
obsolete IPv4-compatible `::/96`; IPv4-mapped `::ffff:0:0/96` uses the
IPv4 policy. It also rejects NAT64 `64:ff9b::/96`, `64:ff9b:1::/48`,
discard `100::/64`, dummy `100:0:0:1::/64`, protocol assignments `2001::/23`,
documentation `2001:db8::/32`, `3fff::/20`, 6to4 `2002::/16`, SRv6 SIDs
`5f00::/16`, unique-local `fc00::/7`, link-local `fe80::/10`, deprecated
site-local `fec0::/10` and multicast `ff00::/8`. Entire protocol-assignment
blocks are denied, including their globally reachable anycast exceptions.

With a proxy, the dialer checks the proxy's address only. The proxy opens
the target connection (and resolves names for socks5h/CONNECT); target
restrictions must be enforced at that proxy. This option cannot inspect
the proxy's chosen destination.

`Trust` is defined in `gaato/mttp/trust` and re-exported by the root
package as `@mttp.Trust`. `Trust::System` is the default and uses
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

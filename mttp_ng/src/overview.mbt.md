# gaato/mttp_ng

HTTP/2 and HTTP/3, client and server, for
[gaato/mttp](https://mooncakes.io/docs/gaato/mttp), on the native target.
The protocols come from the system's nghttp2, nghttp3 and ngtcp2, used
without I/O. The sockets, the timers and TLS (OpenSSL) are driven from
MoonBit on the same runtime as gaato/mttp's HTTP/1.1 engine, so deadlines,
body bounds and phase-tagged errors behave as they do there.

mttp's Client keeps every policy (retries under a budget, deadlines,
redirects, cookies); a backend only moves bytes.

## Install

```sh
moon add gaato/mttp
moon add gaato/mttp_ng
```

Building it needs Node, and pkg-config to find the libraries. The module's
`build.js` runs when your program builds and adds each library to its link
line. Only the packages your program imports are compiled and linked.

| What you import | Needs |
| --- | --- |
| HTTP/2 and HTTP/1.1 (`backend()`, `serve()` without `h3`, `h2client`, `h2server`, `tls`) | nghttp2 1.59 or later, OpenSSL 3.0 or later |
| HTTP/3 (`backend(http3=true)`, `serve(h3=true)`, `h3`, `h3client`, `h3server`) | also ngtcp2 1.12 or later with its OpenSSL crypto library, nghttp3, and OpenSSL 3.5 or later |

The root package imports both, so a program that calls `backend()` or
`serve()` needs the HTTP/3 libraries even when it never asks for HTTP/3.
A program that must build with HTTP/2 alone imports `h2client` and
`h2server` instead.

- openSUSE Tumbleweed: `libnghttp2-devel libopenssl-3-devel nghttp3-devel ngtcp2-devel libngtcp2_crypto_ossl-devel`
- Debian 13: `libnghttp2-dev libssl-dev`, and for HTTP/3 from
  trixie-backports `libngtcp2-dev libngtcp2-crypto-ossl-dev libnghttp3-dev`
  (trixie's own ngtcp2 has no OpenSSL crypto library)

It is tested on Linux with nghttp2 1.71.0, nghttp3 1.19.0, ngtcp2 1.26.0
and OpenSSL 3.5.3, and on Debian 13 with its and trixie-backports'
versions. Its HTTP/2 server passes h2spec 2.6.0 but for the cases
`interop_ng/h2spec_known.tsv` in the repository lists, which are nghttp2's
own handling of frames it no longer tracks or does not validate. Other Linux versions and macOS are not tested yet.
Windows, wasm and js are not supported.

## A client

Give `backend()` to the Client:

```mbt check
///|
pub async fn show_status() -> Unit {
  let api = @mttp.client(
    base_url="https://api.example.com",
    backend=@mttp_ng.backend(http3=true),
  )
  defer api.close()
  let reply = api.send(@mttp.get("/status"))
  println(reply.status)
}
```

`backend()` is `@mttp.backend()` with HTTP/2 and, when asked, HTTP/3:
responses arrive decoded (gzip, deflate, br, zstd), and an
`Accept-Encoding` is offered unless the request names its own.

- `https` origins are offered `h2` and `http/1.1` by ALPN. A server that
  chooses HTTP/2 gets one connection carrying every request to it at once;
  one that chooses HTTP/1.1, or nothing, gets HTTP/1.1 on that same
  connection through gaato/mttp_core's HTTP/1 client, and keeps it for ten
  minutes.
- `http` URLs get HTTP/1.1. `@h2client.H2Backend::new(h2c=true)` speaks
  cleartext HTTP/2 with prior knowledge to servers known to take it.
- `http3=true` tries HTTP/3 (QUIC) first for `https` origins. An origin
  whose QUIC handshake does not finish within a second goes over TCP, and
  is not tried over QUIC again for five minutes; the time QUIC took comes
  off the request's deadline.
- `trust`: `System`, `PemFile(path)` (the roots in that file only) or
  `Insecure`.
- `config` is gaato/mttp_core's `@h1client.ClientConfig`: its phase limits,
  body ceiling, head bound and idle time apply to every protocol; its
  proxy and connection caps to the requests that go over HTTP/1.1. With no
  `config`, the `http_proxy`, `https_proxy`, `all_proxy` and `no_proxy`
  variables are read once, as `@mttp.backend()` reads them.
- `max_connection_age_ms` closes connections at that age once their last
  request ends; zero or less prevents reuse.

## A server

```mbt check
///|
pub async fn serve_ok(cert : String, key : String) -> Unit {
  @mttp_ng.serve(
    _ => @mttp_core.Response::new(200, body=Bytes(b"ok")),
    addr="0.0.0.0:8443",
    cert~,
    key~,
    h3=true,
  )
}
```

`serve()` is `@server.serve` with HTTP/2 and HTTP/3. It uses the same
handler type, listener, admission bound and graceful stop, through
`@server.serve_conns`.

- With `cert` and `key` (PEM: the certificate chain, leaf first, and its
  private key), connections are TLS, and ALPN chooses HTTP/2 or HTTP/1.1.
- With `h3` too, HTTP/3 listens on the same port over UDP. Every TCP
  response then carries `Alt-Svc: h3=":port"; ma=86400` unless the handler
  set one, so that clients find it.
- Without a certificate, connections are cleartext HTTP/1.1, and with
  `h2c` also cleartext HTTP/2 from clients that start with its preface.
  The HTTP/1.1 `Upgrade: h2c` is not offered.
- `limits` (`@h1server.ServerLimits`) applies to every protocol: a
  declared body over `max_body_bytes` is answered 413 before the handler
  runs, a handler over `handler_timeout_ms` 504, and `max_header_bytes`
  bounds every header block. `h2_limits` and `h3_settings` give the
  streams and windows of HTTP/2 and HTTP/3.
- A request carries `@mttp_core.protocol` (`http/1.1`, `h2` or `h3`),
  `connection_scheme` and `remote_addr`.

Cancelling `serve()` stops it. HTTP/1.1 and HTTP/2 connections get
`limits.drain_ms` to finish, and an HTTP/2 client is told to go away first
(GOAWAY). HTTP/3 connections are closed at once.

## What it does not do

- No 0-RTT, no server push, and no WebSockets over HTTP/2 or HTTP/3: a
  request with `Upgrade` goes over HTTP/1.1.
- HTTP/2 and HTTP/3 are not sent through proxies. While a proxy is
  configured for a scheme, its requests go over HTTP/1.1 through it.
- Trailers are not exposed, on either side.
- A QUIC client that changes its address loses its connection: the server
  routes datagrams by the client's address and disables migration.
- Closing a client backend does not send QUIC's CONNECTION_CLOSE; the
  server's idle timeout ends the connection on its side.

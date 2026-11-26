# Changelog

All notable changes to `gaato/mttp_ng` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

### Added

- `backend(trust?, config?, max_connection_age_ms?, http3?)`: gaato/mttp's
  network with HTTP/2 by ALPN on `https` origins, HTTP/1.1 where the server
  or the request needs it, and with `http3=true` HTTP/3 first, falling back
  to TCP for origins without it. Under `@codings.Decompress`, as
  `@mttp.backend()`.
- `serve(handler, addr~, cert?, key?, h2c?, h3?, ...)`: `@server.serve`
  with HTTP/2 by ALPN, cleartext HTTP/2 by prior knowledge with `h2c`, and
  HTTP/3 on the same port with `h3`, advertised by `Alt-Svc`. Cancelling
  it drains every protocol for `limits.drain_ms`, with GOAWAY for HTTP/2
  and HTTP/3; TLS connections end with close_notify unless a body
  delimited by the close was cut short.
- The packages beneath: `tls` (TLS with ALPN over any `rt.Conn`), `h2` and
  `h3` (HTTP/2 and QUIC with HTTP/3 without I/O, over nghttp2, ngtcp2 and
  nghttp3), `h2client` and `h3client` (`Backend`s), `h2server` and
  `h3server`.
- The HTTP/3 server routes datagrams by connection ID, so a client may
  change its address; sends Retry once a quarter of `max_connections` are
  open handshakes; keeps a closed connection's IDs for its closing or
  draining period, sending a lost CONNECTION_CLOSE again; and answers a
  packet for a connection it no longer has with a Stateless Reset. `h3`
  has what a server on a socket of its own needs for that:
  `QuicConn::read(from?)`, `addressed_datagrams`, `connection_ids`,
  `remote_address`, `close_datagram`, `closed_by_peer`, `pto_ms`,
  `destination_cid`, `stateless_reset` and `answer_initial`, the last two
  and `QuicConn::server(keys?)` under a listener's own `ServerKeys`.
- The HTTP/3 client tells the server with CONNECTION_CLOSE whenever it
  closes a connection, `close()` of the backend included, so the server's
  side ends at once rather than at its idle timeout.
- An `https` origin behind a proxy gets HTTP/2 through the proxy's tunnel
  (`@h1client.https_tunnel`); one that chooses http/1.1 there, and `http`
  URLs with a proxy, go over HTTP/1.1 through it, as before.
- `build.js`, run under Node when a program that imports the module
  builds, finds the libraries with pkg-config and puts them on that
  program's link line.

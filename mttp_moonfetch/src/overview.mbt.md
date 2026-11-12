# gaato/mttp_moonfetch

An HTTP/1.1, HTTP/2 and HTTP/3 network backend for the `Client` of
[gaato/mttp](https://mooncakes.io/docs/gaato/mttp), built on
[moonbitstack/moonfetch](https://mooncakes.io/docs/moonbitstack/moonfetch),
for native and wasm.

mttp's Client keeps every policy (retries under a budget, deadlines,
redirects, cookies, typed endpoints); a backend only moves bytes. The
backend of [gaato/mttp_async](https://mooncakes.io/docs/gaato/mttp_async)
speaks HTTP/1.1 over the system's TLS. Use this one instead when an app
wants HTTP/2, with every request to an origin multiplexed on one
connection, or HTTP/3 over QUIC, and runs on native or wasm.

## Install

```sh
moon add gaato/mttp_moonfetch
moon add gaato/mttp_async
```

Then import `gaato/mttp_moonfetch` beside `gaato/mttp_async` in the package
that builds the Client; no experimental opt-in is needed. Before relying on
it, read [Limits](#limits): it follows moonfetch, which is young and changes
quickly.

## Use it

Give `backend()` to `@mttp_async.client`, which keeps all of its defaults:

```mbt check
///|
pub async fn show_status() -> Unit {
  let api = @mttp_async.client(
    base_url="https://api.example.com",
    backend=@mttp_moonfetch.backend(),
  )
  defer api.close()
  let reply = api.send(@mttp_async.get("/status"))
  match reply.body {
    Ok(text) => println("\{reply.status}: \{text}")
    Err(failure) => println(failure)
  }
}
```

A library that builds its own `Client`, such as an API SDK, takes the
backend the same way it takes `@mttp_async.backend()`. Closing the Client
closes the backend's connections.

`backend()` takes three settings, all about connections:

- `http3=true` tries HTTP/3 over QUIC first for `https` origins and falls
  back to TCP for an origin that sends no datagram answer within 3 s. It is
  off by default, as it is in moonfetch, so `backend()` speaks HTTP/1.1 and
  HTTP/2; see [Limits](#limits) before turning it on.
- `proxy` sends every connection through an HTTP, HTTPS or SOCKS5 proxy:
  `proxy=@moonfetch.Proxy::parse("http://proxy.example:3128")`. With a
  proxy, `http3=true` has no effect: moonfetch would dial QUIC straight to
  the origin, around the proxy.
- `tls` replaces moontls's client settings, for example to trust a private
  certificate authority:
  `tls=@tls.Client::new(@x509.Roots::pem(ca_pem))`, with
  `moonbitstack/moontls/tls` and `moonbitstack/mooncred/x509` imported.

Each response carries the HTTP version it arrived over:

```mbt check
///|
pub async fn version_of(url : String) -> String? {
  let backend = @mttp_moonfetch.backend()
  defer backend.close()
  let response = backend.send(
    @mttp.Request::get(url),
    @mttp.SendOptions::default(),
  )
  response.close()
  response.attributes.get(@mttp_moonfetch.http_version)
}
```

## What it does

- One exchange per `send`, on a moonfetch client of the backend's own. An
  HTTP/2 or HTTP/3 connection carries every request to its origin, for 1000
  requests: moonfetch 0.1.8 keeps an entry for each stream a connection
  opened until the connection closes, so after 1000 sends the backend moves
  to a new client with new connections and closes the old one once its last
  response is closed.
- An HTTP/1.1 exchange takes a fresh connection. moonfetch keeps idle
  HTTP/1.1 connections with no age limit and cannot tell that the server
  closed one until a request fails on it, after the request was written;
  mttp's Client would then not resend a POST.
- Responses are decompressed (gzip, deflate, br, zstd) exactly as
  `@mttp_async.backend()` does it: `Accept-Encoding` is added only when the
  request has none, and a request that names its own gets the body as sent.
- Redirects, retries and cookies are left to the Client: a 3xx comes back as
  it is, and moonfetch's own redirects, decompression and cookie jar are off.
- The per-send options are kept. `timeout_ms` bounds the wait for the
  response head, and the whole body as well when the Client reads the body
  in full. That body is limited in bytes as they arrive, before decoding. A
  streamed body waits at most the idle limit for each read.
- A failure says whether the request may have been sent. Resolving the
  host, connecting, the TLS handshake and the proxy come before the request,
  and so does a request the server refused before processing it and before
  any response head (HTTP/3 `H3_REQUEST_REJECTED`; HTTP/2 `REFUSED_STREAM`
  for a request without a body), and a stream not opened because the server
  allows no more at once or sent GOAWAY: the Client may send those again
  whatever the method. moonfetch raises `REFUSED_STREAM` itself too when a connection
  dies while a request body waits for flow-control window, after part of it
  was written, so for a request with a body that code proves nothing. Any
  other failure may have come after the request was written, and only an
  idempotent request is sent again.
- A streamed request body is read once and closed. Its first piece is read
  before anything is written, so a body that fails at once sends nothing.
  Over HTTP/2 and HTTP/3 the body is sent as it is read; over HTTP/1.1
  moonfetch collects the whole body in memory before writing it.

## What it does not do

- It does not build for js. There, `gaato/mttp_async` already uses the
  host's `fetch`, and the browser or runtime negotiates HTTP/2 and HTTP/3
  itself; moonfetch would only make the bundle larger.
- It does not read the `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY`
  environment variables, which `@mttp_async.backend()` does.
- The `Host` header comes from the URL. A request's own `Host`,
  `Content-Length` or `Transfer-Encoding` field is dropped, because moonfetch
  writes those itself.
- It has no connection limits, per-phase timeouts or idle-connection expiry
  to configure, unlike `@mttp_async.backend(config=...)`.

## Limits

- **It follows moonfetch, 0.x.** moonfetch changes quickly, is still 0.x
  and has one maintainer. Telling a sent request from an unsent one depends
  on moonfetch's error types, and for one case on an error message, which
  any moonfetch release may change. A daily canary builds this module
  against the newest moonfetch and runs it against public HTTP/2 and HTTP/3
  servers to catch that. The package is not marked experimental, so no
  opt-in is needed; these limits are its status instead.
- **One failed HTTP/2 or HTTP/3 exchange closes its connection.** When an
  exchange fails before its response head, moonfetch 0.1.8 drops the shared
  connection, so the other responses still arriving on it fail too. That
  includes a request past the server's concurrent-stream limit: moonfetch
  does not wait for a stream to free up. The request itself is unsent and
  the Client resends it on a new connection; a response cut that way is a
  failure in phase Body.
- **TLS is moonbitstack's own.** The TLS protocol (moontls), its
  cryptography (mooncrypt) and certificate validation (mooncred) are
  moonbitstack's MoonBit libraries, not a widely deployed implementation
  such as OpenSSL. moontls's README describes interoperability tests
  against OpenSSL and pion, and names one limit: modular exponentiation for
  RSA key exchange is not constant time (RSA key exchange is not among its
  default TLS 1.2 suites). Servers are checked against the Mozilla root
  store bundled with mooncred, not the operating system's. When that
  matters, use `@mttp_async.backend()`, which uses the system's OpenSSL on
  Linux and macOS, Schannel on Windows and the host's TLS on js.
- **HTTP/3 with moonfetch 0.1.8.** Over HTTP/3 a larger response body can
  fail partway (with moonhttp's `Incomplete`), for example an uncompressed
  page; compressed bodies, which this backend asks for by default, have read
  whole in testing. Weigh that before passing `http3=true`, and in
  particular for a request that names its own `Accept-Encoding`.

## Links

- [gaato/mttp](https://github.com/gaato/mttp): the Client, the Backend
  contract and the backend of `gaato/mttp_async`.
- [moonbitstack/moonfetch](https://github.com/moonbitstack/moonfetch): the
  HTTP client underneath.
- [moonbitstack/moontls](https://github.com/moonbitstack/moontls): its TLS.

## License

Apache-2.0

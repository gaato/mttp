# gaato/mttp_curl

HTTP/2 and HTTP/3 for the `Client` of
[gaato/mttp](https://mooncakes.io/docs/gaato/mttp), over the system's
libcurl, for native. gaato/mttp's own network backend speaks HTTP/1.1;
this one speaks HTTP/1.1 and HTTP/2, chosen by ALPN, with every request to
an `https` origin on one HTTP/2 connection, and HTTP/3 when asked for.

mttp's Client keeps every policy (retries under a budget, deadlines,
redirects, cookies); a backend only moves bytes.

## Install

```sh
moon add gaato/mttp
moon add gaato/mttp_curl
```

It links the system's libcurl, 7.85 or later, built with HTTP/2:

- Debian and Ubuntu: `apt-get install libcurl4-openssl-dev`
- Fedora and openSUSE: `libcurl-devel`
- macOS: the libcurl that comes with the system

HTTP/3 needs a libcurl built with it, such as Debian 13's; Apple's has
none. It builds for the native target on Linux and macOS, not on Windows,
wasm or js. On js, gaato/mttp's backend is the host's `fetch`, which
negotiates HTTP/2 and HTTP/3 itself.

## Use it

Give `backend()` to the Client:

```mbt check
///|
pub async fn show_status() -> Unit {
  let api = @mttp.client(
    base_url="https://api.example.com",
    backend=@mttp_curl.backend(),
  )
  defer api.close()
  let reply = api.send(@mttp.get("/status"))
  println(reply.status)
}
```

`backend()` is to libcurl what `@mttp.backend()` is to gaato/mttp's own
engine: responses arrive decoded (gzip, deflate, br, zstd), and an
`Accept-Encoding` is offered unless the request names its own. A library
that builds its own Client, such as an API SDK, takes it the same way.
`CurlBackend::new` takes the same settings and returns the bytes as they
arrived, for a caller that decodes them itself.

The settings:

- `http3=true` tries HTTP/3 first for `https` URLs and falls back to TCP.
  `CurlBackend::supports_http3()` says whether the linked libcurl can;
  when it cannot, every send fails with `Invalid` before any I/O.
- `trust`: `System` (libcurl's default authorities), `PemFile(path)`
  (those in the file instead) or `Insecure` (no certificate check). It
  applies to an HTTPS proxy as well.
- `proxy`: by default the `http_proxy`, `https_proxy`, `all_proxy` and
  `no_proxy` variables, read once when the backend is made, as
  `@mttp.backend()` reads them. `@h1client.ProxyConfig::none()` (from
  `gaato/mttp_core/h1client`) turns proxies off, and
  `@h1client.ProxyConfig::fixed(url)` names one. The tests use an
  `http://` proxy; libcurl also takes `https://` and `socks5h://` proxy
  URLs. `no_proxy` is matched by libcurl's rules.
- `max_connection_age_ms` closes connections at that total age; zero or
  less prevents reuse.

## What it does

- Each response carries the protocol that carried it under
  `@mttp_core.protocol`: `http/1.1`, `h2` or `h3`.
- A request's `@mttp_core.on_phase` callback, and so the Client's
  `events`, get `Dialed`, `TlsDone` and `Pooled` once the connection is
  ready, then `Written` and `FirstByte`. `Dialed` names the host and port
  dialled (the proxy's when there is one). With a libcurl before 8.10 there
  is no `Written`, since libcurl does not say when the request was sent.
- A failure says whether the request may have been sent. Resolving,
  connecting, TLS and the proxy's tunnel come before it (phase `Dial`); a
  refused tunnel is `Proxy(status)`. The Client may send those again
  whatever the method.
- libcurl itself sends a request again on a new connection when the server
  refuses its HTTP/2 or HTTP/3 stream, or names it above a GOAWAY, up to
  five times, and the Client's retry budget does not count those. When all
  five are refused, the error is `Refused`, which also counts as unsent.
- A final response that arrives while a streamed request body is still
  being sent stops the upload: the rest of the body is not read, the
  stream is closed, and that connection is not used again.
- The response head is bounded at 64 KiB (`TooLarge` in phase `Head`).
  `SendOptions` bound the body and the deadlines as for any backend.
- Redirects, retries and cookies are left to the Client: a 3xx comes back
  as it is, and libcurl's own redirects, decoding and cookies are off.

## What it does not do

- CONNECT requests and protocol upgrades (such as WebSockets) are refused
  with `Invalid` before any I/O: libcurl cannot hand a connection over.
  Use `@mttp.backend()` for those.
- Trailers and 1xx responses are not exposed.
- The connection settings of `@mttp.backend(config=...)` (connection
  limits, per-phase timeouts) have no counterpart here.

## License

[Apache-2.0](https://github.com/gaato/mttp/blob/main/LICENSE)

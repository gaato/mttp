# gaato/mttp_curl

An HTTP/2 and HTTP/3 backend for the `Client` of
[gaato/mttp](https://mooncakes.io/docs/gaato/mttp), over the system's
libcurl, for native. **It is a prototype: it is not published on
mooncakes.io, and its API may change or the module may be dropped.**

mttp's Client keeps every policy (retries under a budget, deadlines,
redirects, cookies); a backend only moves bytes. gaato/mttp's own backend
speaks HTTP/1.1. `CurlBackend` speaks HTTP/1.1 and HTTP/2, chosen by ALPN,
with every request to an origin on one HTTP/2 connection, and HTTP/3 when
asked for.

## Install

There is nothing to install from the registry yet. Inside the
[gaato/mttp](https://github.com/gaato/mttp) repository it is the
`mttp_curl` member of `moon.work`. It links the system's libcurl, 8.10 or
later with HTTP/2 (`libcurl4-openssl-dev` on Debian, `libcurl-devel` on
openSUSE), and builds on native Linux only.

## Use it

Wrap it in `Decompress`, as gaato/mttp's own network backend is, and give
it to the Client:

```mbt check
///|
pub async fn show_status() -> Unit {
  let backend = @codings.Decompress::new(@mttp_curl.CurlBackend::new())
  let api = @mttp.client(base_url="https://api.example.com", backend~)
  defer api.close()
  let reply = api.send(@mttp.get("/status"))
  println(reply.status)
}
```

`CurlBackend::new` takes three settings:

- `http3=true` tries HTTP/3 first for `https` URLs and falls back to TCP.
  `CurlBackend::supports_http3()` says whether the linked libcurl can; when
  it cannot, every send fails with `Invalid`.
- `trust`: `System` (libcurl's default authorities), `PemFile(path)` (those
  in the file instead) or `Insecure` (no certificate check).
- `max_connection_age_ms` closes connections at that total age; zero or
  less prevents reuse.

Each response carries the protocol that carried it under
`@mttp_core.protocol` (`http/1.1`, `h2` or `h3`).

## What it does not do

- Proxies: none are used, and the proxy variables are not read.
- CONNECT and protocol upgrades (WebSockets): refused before any I/O.
- Phase events: none are reported.
- Trailers and 1xx responses are not exposed.

## License

[Apache-2.0](https://github.com/gaato/mttp/blob/main/LICENSE)

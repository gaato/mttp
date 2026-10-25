# HTTP/1 socket backend

`H1Backend` implements `mttp/client.Backend` on native and moonrun wasm.
It uses the bounded `mttp/h1` parser and incremental content decoders. HTTPS
uses the system trust roots and validates the peer name. Compose
`FollowRedirects` and `Cookies` when those policies are wanted.

```mbt check
///|
test "construct and close a bounded connection pool" {
  let backend = @backend.H1Backend::new(
    trust_env=false,
    max_connections=16,
    max_connections_per_origin=4,
    max_idle_connections=32,
  )
  assert_eq(backend.idle_connections(), 0)
  backend.close()
}
```

Keep the response alive while reading its body, and always close it if reading
stops early. EOF returns the socket to the pool only after framing and content
decoding have completed. Closing the backend closes parked sockets and refuses
queued calls; an in-flight response still owns its socket until consumed or
closed.

The default exchange timeout is 30 seconds, the idle pool retains at most 256
sockets in total and four per origin for ten seconds, and buffered responses
use `RequestOptions.max_body_bytes` (64 MiB by default). Streaming readers own
their total byte limit and retain a per-read timeout. Read and write slices are
at most 64 KiB; input heads, chunk lines and trailers have the `h1.Limits`
bounds. The caller chooses active connection caps; these are unset by default.

An explicit `proxy` URL overrides environment routing. Otherwise `trust_env`
(true by default) snapshots `http_proxy`, `https_proxy`, `all_proxy`, and
`no_proxy`, with uppercase fallbacks. Lowercase settings take precedence;
uppercase `HTTP_PROXY` is ignored in CGI environments. `trust_env=false`
disables environment routing. A malformed selected proxy fails before dialling
instead of silently going direct. NO_PROXY supports domain suffixes, ports,
IPv4/IPv6 addresses and CIDR networks, with the mature curl/Go reference tests.

HTTP requests use absolute targets through an HTTP(S) proxy. HTTPS uses a
bounded CONNECT exchange, then verified end-to-end TLS (nested inside proxy
TLS for an HTTPS proxy). Proxy URL credentials are percent-decoded into Basic
authentication and sent only to the proxy. User-supplied Proxy-Authorization
is replaced or removed. Pool keys include the route and canonical origin with
an explicit port, so forwarded, tunnelled and direct connections cannot mix.

A JS fetch backend remains pending. User-issued successful CONNECT and 101
responses close their socket because this API does not expose tunnels.

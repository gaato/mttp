# HTTP/1 socket backend

`H1Backend` implements `mttp/client.Backend` on native and moonrun wasm.
It uses the bounded `mttp/h1` parser and incremental content decoders. HTTPS
uses the system trust roots and validates the peer name. Compose
`FollowRedirects` and `Cookies` when those policies are wanted.

```mbt check
///|
test "construct and close a bounded connection pool" {
  let backend = @backend.AsyncBackend::new(
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

User-issued successful CONNECT and 101 responses close their socket because
this API does not expose tunnels.

## Portable backend and JS

`AsyncBackend` selects H1Backend on native/wasm and fetch on JS, keeping the
same constructor and Backend interface. Fetch uses `redirect: "manual"` so a
single send never silently follows a redirect. In browsers an opaque redirect
has no accessible status or Location and is reported as Protocol/Unknown;
Node exposes its ordinary redirect response. Browser CORS, forbidden headers
and platform proxy settings remain in effect.

Fetch always negotiates and decodes content codings, even when `decompress`
is false or Accept-Encoding was supplied; it reports the platform's headers,
which may still describe encoded bytes. The adapter therefore does not claim
a stream length from Content-Length. Set-Cookie values are preserved when the
host exposes getSetCookie; browsers normally hide them.

JS stream uploads are buffered up to 16 MiB, with oversized declared lengths
refused before taking the stream. Byte bodies are already caller-owned and
are not subject to that stream-buffer ceiling. GET/HEAD bodies and methods
forbidden by fetch are refused. Response slices are at most 64 KiB, retaining
at most one host-provided chunk without repeatedly copying its remainder.
Buffered decoded byte limits and read deadlines still apply. At most 1024
consecutive empty host chunks are tolerated before Protocol/Body is raised.
Header buffering and individual host chunk sizes are controlled by fetch.

Cancellation aborts the fetch and cancels its reader, removes the read's abort
listener, and returns its admission slot. Before the response head, fetch
does not expose DNS/connect/write phases, so network failures and timeouts
are reported in Unknown. Body failures retain Body. Socket idle-pool settings,
head limits and trust_env have no effect on JS; explicit proxy URLs are
rejected rather than ignored.

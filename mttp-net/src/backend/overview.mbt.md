# HTTP/1 socket backend

`H1Backend` implements `mttp/client.Backend` on native and moonrun wasm.
It uses the bounded `mttp/h1` parser and incremental content decoders. HTTPS
uses the system trust roots and validates the peer name. Compose
`FollowRedirects` and `Cookies` when those policies are wanted.

```mbt check
///|
test "construct and close a bounded connection pool" {
  let backend = @backend.H1Backend::new(
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

Proxy routing and a JS fetch backend remain pending. Successful CONNECT and
101 responses close their socket because this API does not expose tunnels.

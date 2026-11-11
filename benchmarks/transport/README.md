# Loopback transport benchmark

From the workspace root:

```sh
MOON_CC=cc moon run benchmarks/transport --target native --release
```

Measures microseconds per request over one reused TCP connection using
`gaato/mttp_async/backend` and `gaato/http/h1server`. Each sample warms up
with 32 requests, measures 500 GETs returning `pong`, and checks the response
and connection reuse. The output is the median of three samples for each
server write size (65536 bytes and one byte), matching the old workload.
An explicit default client configuration disables environment proxies, so
the measurement stays on loopback even on a host configured with a proxy.
TCP can coalesce writes, so write sizes do not imply packet or read sizes.

The server now uses the HTTP/1 engine instead of a handwritten response.
Absolute timings therefore include both engines and are not directly
comparable with the old raw-socket server. Gates build this native-only,
unpublished executable without running it; timings depend on the host.

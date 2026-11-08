# Async client backend

`AsyncBackend` implements `gaato/http.Backend` on native, wasm1 under
moonrun, and JS. Each send performs one exchange. It returns redirects and
does not retry or store cookies. Close every response after reading it or
when abandoning its body; close the backend when finished.

```mbt check
///|
test "construct and close a cross target backend" {
  let backend = @backend.AsyncBackend::new()
  assert_eq(backend.idle_connections(), 0)
  backend.close()
  backend.close()
}
```

On native/wasm the backend composes `h1client.Client`, `conn.TcpDialer`,
the ports from `runtime`, and `codings.Decompress`. It negotiates gzip,
deflate, Brotli and zstd and lazily decodes bounded slices. A request that
supplies `Accept-Encoding` opts out: its returned body and coding headers
are unchanged. `SendOptions` pass through unchanged, so byte limits in the
engine count wire bytes before decoding. Bound decoded bytes separately
with `@http.read_bounded`. Reading to EOF permits connection reuse; closing
early discards the connection.

With no `config`, proxy variables are captured from the process environment
at construction via `ProxyConfig::from_env`. An explicit `ClientConfig` is
used verbatim, including `ProxyConfig::none()` to disable environment
proxies. To combine custom settings with environment proxy lookup, set
`proxy: @h1client.ProxyConfig::from_env(@env.get_env_var)` in the config.
The engine handles proxy authentication, CONNECT and NO_PROXY. `trust`
accepts the root package's `gaato/http-async.Trust`, defaulting to `System`.
`PemFile` replaces system roots; combine roots in that file when necessary.

JS uses the host's fetch and ReadableStream reader over core `js_async`.
Only `ClientConfig.max_body_bytes` applies. Its proxy, connection, phase
timeout and header settings, and the separate `trust` argument, are ignored;
fetch uses the host's proxy configuration and trust store. Network failures
carry phase Unknown because fetch cannot identify the wire phase. Forbidden
methods, malformed requests and framing conflicts are refused before fetch.
Fetch sets `credentials: 'omit'` to disable implicit browser credentials,
including sending stored cookies and accepting Set-Cookie into its cookie store.
Fetch is called with manual redirects; browsers can hide redirect responses
as opaque responses, which are refused. Browsers may merge header fields or
hide Set-Cookie. Hosts exposing `getSetCookie` retain separate cookie fields.

Fetch always negotiates and decodes content codings, even with an explicit
Accept-Encoding. Its original coding/length headers may remain visible.
Consequently JS byte limits count host-delivered decoded bytes, and cannot
limit compressed wire bytes. Stream uploads are buffered before fetch, to
at most 16 MiB; byte uploads share that cap. Response delivery is sliced to
64 KiB, and 1024 consecutive empty host chunks are refused. The host owns
allocation of each original chunk; slicing does not bound that allocation.
The reader is used directly because core's ReadableStream adapter skips
empty chunks without a budget.

`SendOptions.timeout_ms` covers upload and head, plus all body reads for
`Exchange`. `Exchange.max_bytes` is capped by the configured ceiling. For
`Stream`, the attempt deadline ends at the head and each subsequent read
uses `idle_ms`; the configured ceiling still applies. Timeout, early close,
read error and caller cancellation abort fetch and cancel its body reader.
Cancellation propagates unchanged. `idle_connections()` is zero on JS,
whose connection pool belongs to the host.

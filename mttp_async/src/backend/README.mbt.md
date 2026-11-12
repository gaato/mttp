# gaato/mttp_async/backend

The network as a `Backend`, for native, wasm (under moonrun) and js.

`AsyncBackend` implements `@mttp.Backend`. Each send performs one exchange.
It returns redirects and does not retry or store cookies. Close every
response after reading it or when abandoning its body; close the backend
when finished.

```mbt check
///|
test "construct and close a cross target backend" {
  let backend = @backend.AsyncBackend::new()
  assert_eq(backend.idle_connections(), 0)
  backend.close()
  backend.close()
}
```

On native and wasm the backend is `gaato/mttp`'s HTTP/1.1 client engine over
TCP and TLS, with decompression. It negotiates gzip, deflate, Brotli and
zstd and decodes lazily in bounded slices. A request that supplies
`Accept-Encoding` opts out: its returned body and coding headers are
unchanged. `SendOptions` pass through unchanged, so byte limits in the
engine count wire bytes before decoding. Bound decoded bytes separately
with `@mttp.read_bounded`. Reading to EOF permits connection reuse; closing
early discards the connection.

With no `config`, proxy variables are captured from the process environment
at construction via `ProxyConfig::from_env`. An explicit `ClientConfig` is
used verbatim, including `ProxyConfig::none()` to disable environment
proxies. To combine custom settings with environment proxy lookup, set
`proxy: @h1client.ProxyConfig::from_env(@env.get_env_var)` in the config.
The engine handles proxy authentication, CONNECT and NO_PROXY. `trust` takes
a `Trust` (from `gaato/mttp_async/trust`, re-exported by the root package),
defaulting to `System`. `PemFile` replaces system roots; combine roots in
that file when necessary.

The optional `clock` and `timer` arguments accept `gaato/mttp/rt` ports on
every target. The clock defaults to `runtime.AsyncClock`; the timer defaults
to `runtime.ClockTimer` built on the chosen clock. On native and wasm they
drive pool idle expiry (checked when the pool is used) and phase deadlines.
For controlled tests, pass `clock=virtual_clock`, optionally with
`timer=@runtime.ClockTimer::new(clock=virtual_clock)`. Passing just the clock
also puts the default timer on virtual time.

On js the backend uses the host's `fetch`. Only `ClientConfig.max_body_bytes`
applies. Its proxy, connection, phase timeout and header settings, and the
separate `trust` argument, are ignored; fetch uses the host's proxy
configuration and trust store. Network failures carry phase Unknown because
fetch cannot identify the wire phase. Forbidden methods, malformed requests
and framing conflicts are refused before fetch. Fetch sets
`credentials: 'omit'` to disable implicit browser credentials, including
sending stored cookies and accepting Set-Cookie into its cookie store. Fetch
is called with manual redirects; browsers can hide redirect responses as
opaque responses, which are refused. Browsers may merge header fields or
hide Set-Cookie. Hosts exposing `getSetCookie` retain separate cookie fields.

Fetch always negotiates and decodes content codings, even with an explicit
Accept-Encoding. Its original coding/length headers may remain visible.
Consequently js byte limits count host-delivered decoded bytes, and cannot
limit compressed wire bytes. Stream uploads are buffered before fetch, to
at most 16 MiB; byte uploads share that cap. Response delivery is sliced to
64 KiB, and 1024 consecutive empty host chunks are refused. The host owns
allocation of each original chunk; slicing does not bound that allocation.

`SendOptions.timeout_ms` covers upload and head, plus all body reads for
`Exchange`. `Exchange.max_bytes` is capped by the configured ceiling. For
`Stream`, the attempt deadline ends at the head and each subsequent read
uses `idle_ms`; the configured ceiling still applies. Timeout, early close,
read error and caller cancellation abort fetch and cancel its body reader.
Cancellation propagates unchanged. These deadlines use the injected clock
and timer too. `idle_connections()` is zero on js, whose connection pool
belongs to the host.

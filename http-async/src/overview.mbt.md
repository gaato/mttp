# gaato/http-async

Runtime adapters for [`gaato/http`](https://mooncakes.io/docs/gaato/http) on
`moonbitlang/core/async`: TCP and TLS connections, a client backend, a server
listener, content codings (gzip, deflate, br, zstd) and a fetch backend for
JavaScript hosts. The runtime adapters are implemented: `runtime`, `codings`
and `backend` build on native, wasm and js; `conn` and `server` on native and
wasm; `fetch` and the host shims on js. The examples cover a bounded GET,
a keep-alive HTTP/1 listener and real exported fetch functions.

| Package | Targets | Purpose |
|---|---|---|
| root | native, wasm, js | Portable `Trust` policy for socket dialers and backends |
| `backend` | native, wasm, js | `AsyncBackend`: HTTP/1 + Decompress on sockets; host fetch on JS |
| `runtime`, `codings` | native, wasm, js | Runtime ports and content-coding wrappers |
| `conn` | native, wasm | TCP and TLS over the portable connection trait |
| `server` | native, wasm | Bounded TCP listener, graceful shutdown and background ownership |
| `fetch`, `hosts` | js | Streaming Web Request handlers; Workers, Fastly, Vercel, Node, Deno, Bun and Lambda shims |

`gaato/http-async/backend.AsyncBackend::new()` performs one request at a
time per call and returns a response owned by the caller. Native/wasm use
the HTTP/1 engine with automatic decoding unless the request supplies its
own `Accept-Encoding`. With no config, proxies come from the process
environment; an explicit `ClientConfig` supplies the complete configuration.
On JS only its `max_body_bytes` applies: fetch controls proxies, connection
pooling, header limits, trust and content decoding. Socket `Trust` lives in
this root package so the constructor is identical across targets.
Optional `clock` and `timer` ports drive socket pool expiry and phase timers,
and fetch upload/head/body deadlines. The defaults are `AsyncClock` and a
`ClockTimer` on the chosen clock; passing only `clock` controls both.

`gaato/http-async/runtime` supplies clocks, timers, a FIFO admission gate and
structured coordination through the portable `gaato/http/rt` traits. Its
`VirtualClock` lets runtime tests advance deadlines manually.
`gaato/http-async/conn` dials TCP and upgrades any portable connection to
TLS, including CONNECT tunnels. `gaato/http-async/codings` provides bounded
codecs, `Decompress` for backends and `compress` for handlers. Neither the
connection engines nor these adapters follow redirects or retry requests.

`gaato/http-async/server.serve(handler, addr~)` accepts at most 256 connections
by default and drains active responses and background jobs on cancellation.
`ListenError` distinguishes configuration, bind and accept failures; connection
failures reach `on_error` as `http.TransportError`. Supply
`codings.compress(handler)` when serving compressed content.
`gaato/http-async/fetch.fetch_handler(handler)` adapts Web Request/Response
with a 1 MiB request ceiling, 64 KiB delivered chunks, abort cancellation and
synchronous aggregate background registration. The host shims in `hosts/`
adapt the platform's environment and background lifetime; Lambda buffers
bounded output and preserves absent bodies as `Body::Empty`.

Wasm here means wasm1 under moonrun. wasm-gc applications use `gaato/http`
and provide their own runtime ports; this module does not build on wasm-gc.
Applications importing both HTTP roots should give
`moonbitlang/core/async/http` an explicit alias such as `@corehttp` to avoid
colliding with the `@http` alias of `gaato/http`.

`moonbitlang/core/async` is an experimental part of the standard library. A
package that imports it lists it in its `moon.pkg`:

```
options("allow-experimental-packages": ["moonbitlang/core/async"])
```

## Install

```sh
moon add gaato/http-async
```

## License

Apache-2.0

# gaato/http-async

Runtime adapters for [`gaato/http`](https://mooncakes.io/docs/gaato/http) on
`moonbitlang/core/async`: TCP and TLS connections, a client backend, a server
listener, content codings (gzip, deflate, br, zstd) and a fetch backend for
JavaScript hosts. The available packages are `runtime` and `codings` on
native, wasm and js, and `conn` on native and wasm. Client backends and
listener/fetch adapters are subsequent steps of the rebuild.

`gaato/http-async/runtime` supplies clocks, timers, a FIFO admission gate and
structured coordination through the portable `gaato/http/rt` traits. Its
`VirtualClock` lets runtime tests advance deadlines manually.
`gaato/http-async/conn` dials TCP and upgrades any portable connection to
TLS, including CONNECT tunnels. `gaato/http-async/codings` provides bounded
codecs, `Decompress` for backends and `compress` for handlers. Neither the
connection engines nor these adapters follow redirects or retry requests.

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

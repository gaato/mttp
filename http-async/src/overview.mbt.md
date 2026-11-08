# gaato/http-async

Runtime adapters for [`gaato/http`](https://mooncakes.io/docs/gaato/http) on
`moonbitlang/core/async`: TCP and TLS connections, a client backend, a server
listener, content codings (gzip, deflate, br, zstd) and a fetch backend for
JavaScript hosts. It runs on native, wasm and js.

> **Status**: this version is being rebuilt in the
> [mttp repository](https://github.com/gaato/mttp). The packages arrive one
> at a time; until then this module has no public API.

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

# gaato/mttp

HTTP for [MoonBit](https://www.moonbitlang.com/) with the split of
responsibilities of Scala's [sttp](https://sttp.softwaremill.com/) family, on
top of [`gaato/http`](https://mooncakes.io/docs/gaato/http): a client that owns
retries, rate limits and deadlines, server-sent events, multipart bodies,
cookies, endpoint descriptions with server and client interpreters, a router
and OpenAPI documents. It does no I/O itself and runs on wasm-gc, wasm, js and
native.

> **Status**: this version is being rebuilt in the
> [mttp repository](https://github.com/gaato/mttp). The packages arrive one
> at a time; until then this module has no public API.

## Install

```sh
moon add gaato/mttp
```

## License

Apache-2.0

# gaato/http

The HTTP vocabulary for [MoonBit](https://www.moonbitlang.com/): methods,
headers, URLs, requests, responses and bodies, a sans-IO HTTP/1.1 codec, and
client and server connection engines that run on ports (connections, clocks,
timers) supplied by the caller. It depends on nothing but `moonbitlang/core`
and builds on wasm-gc, wasm, js and native.

> **Status**: this version is being rebuilt in the
> [mttp repository](https://github.com/gaato/mttp). The packages arrive one
> at a time; until then this module has no public API.

Sockets, TLS, an event loop and content codings live in
[`gaato/http-async`](https://mooncakes.io/docs/gaato/http-async), and the
client with retries, cookies and endpoints lives in
[`gaato/mttp`](https://mooncakes.io/docs/gaato/mttp).

## Install

```sh
moon add gaato/http
```

## License

Apache-2.0

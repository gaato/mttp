# mttp

HTTP for [MoonBit](https://www.moonbitlang.com/): a client with retries,
deadlines, rate limits, redirects and cookies; a server; server-sent events
and multipart bodies; and typed endpoints that one definition turns into a
client call, a server handler and an OpenAPI document. Everything without
I/O lives in one module that builds on every target, and a second module
connects it to the network through `moonbitlang/core/async`. The split
follows Scala's [sttp](https://sttp.softwaremill.com/) family.

## Modules

| Module | Add it if |
|---|---|
| [`gaato/mttp_async`](https://mooncakes.io/docs/gaato/mttp_async) | you are building an app or a server: it sends requests over the network with sensible defaults, serves handlers, and re-exports the types and client functions an app uses most. Add `gaato/mttp` beside it for typed endpoints, the router, OpenAPI documents, multipart bodies, rate limits and test stubs. |
| [`gaato/mttp`](https://mooncakes.io/docs/gaato/mttp) | you are writing a library, such as an SDK for some API: it takes a `Client` and leaves the network to the app, so its tests run without one. |
| [`gaato/mttp_digest`](https://mooncakes.io/docs/gaato/mttp_digest) | a server asks for HTTP Digest authentication. |

## Examples

- [examples/get](examples/get): one GET request from the command line.
- [examples/serve](examples/serve): an HTTP/1.1 server.
- [examples/fetch](examples/fetch): a `fetch` export for JavaScript hosts,
  with a [Cloudflare Workers app](examples/fetch/workers).

## Implementing a backend or a runtime

[CONTRACT.md](CONTRACT.md) states what a backend, a runtime adapter or a test
double must guarantee, and what code using them may rely on.

## Coming from gaato/http

`gaato/http` and `gaato/http-async` are now `gaato/mttp` and
`gaato/mttp_async`; the [changelog of gaato/mttp](mttp/CHANGELOG.md) says
what to rename.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

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
> at a time: `jsonkit`, `sse`, `multipart`, `cookie` and the client with
> its retry rules are here; the client's wrappers and test doubles, rate
> limits, schemas, endpoints, the router and OpenAPI follow.

## Install

```sh
moon add gaato/mttp
```

A package that names `@http` types imports `gaato/http` too, so list both in
your `moon.mod`.

## Packages

| Package | What it holds |
|---|---|
| `gaato/mttp/jsonkit` | `Presence` (omitted, `null` or a value), an object builder, field decoders and open enums for JSON models |
| `gaato/mttp/sse` | An incremental, bounded `text/event-stream` parser and an event encoder |
| `gaato/mttp/multipart` | A `multipart/form-data` writer with streamed file parts and injected boundary randomness |
| `gaato/mttp/cookie` | An RFC 6265 cookie jar on an injected clock |
| `gaato/mttp/client` | Request and response plans with Result-valued readers, and the `Client` send loop: defaults, admission, deadlines, decoded-body limits and retries |
| `gaato/mttp/client/retry` | Retry rules and decisions as data, and the Retry-After parsers |

## Usage

Build an upload and read a server-sent event stream. Neither touches the
network: a transport from `gaato/http-async`, or a test double, sends the
request and supplies the chunks.

```mbt check
///|
test "an upload and an event stream" {
  let request = @multipart.body(
    @http.Request::post("https://example.com/upload"),
    [@multipart.Part::json("meta", { "draft": true })],
    boundary=@multipart.make_boundary(() => 0.25),
  )
  assert_true(request.headers.get("content-type") is Some(_))
  let parser = @sse.SseParser::new()
  let events = parser.feed(b"data: one\n\ndata: tw")
  events.append(parser.feed(b"o\n\n"))
  assert_eq(events.map(e => e.data), ["one", "two"])
}
```

## License

Apache-2.0

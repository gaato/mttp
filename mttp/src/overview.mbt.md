# gaato/mttp

HTTP for [MoonBit](https://www.moonbitlang.com/) with the split of
responsibilities of Scala's [sttp](https://sttp.softwaremill.com/) family, on
top of [`gaato/http`](https://mooncakes.io/docs/gaato/http): a client that owns
retries, rate limits and deadlines, server-sent events, multipart bodies,
cookies and schemas. It does no I/O itself and runs on wasm-gc, wasm, js and
native.

Typed endpoints with server and client interpreters, the router and OpenAPI
documents live in
[`gaato/mttp_endpoint`](https://mooncakes.io/docs/gaato/mttp_endpoint).

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
| `gaato/mttp/client` | Request and response plans with Result-valued readers, the `Client` send loop (defaults, admission, deadlines, decoded-body limits, retries), `FollowRedirects`, `Paginator`, Retry-After and `Link` helpers |
| `gaato/mttp/client/retry` | Retry rules and decisions as data, and the Retry-After parsers |
| `gaato/mttp/client/ratelimit` | Bounded window state, grouped pacing, global quotas and header-driven admission on an injected clock |
| `gaato/mttp/client/cookies` | A CookieJar backend wrapper; put it inside FollowRedirects to process every hop |
| `gaato/mttp/testing` | `BackendStub`, canned answers and fault injection for client tests |
| `gaato/mttp/schema` | Text, JSON and body codecs that carry their JSON Schema, validators, and decoding that collects every issue with its JSON pointer |

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

# gaato/http

The HTTP vocabulary for [MoonBit](https://www.moonbitlang.com/): methods,
headers, URLs, requests, responses and bodies, a sans-IO HTTP/1.1 codec, and
client and server connection engines that run on ports (connections, clocks,
timers) supplied by the caller. It depends on nothing but `moonbitlang/core`
and builds on wasm-gc, wasm, js and native.

> **Status**: this version is being rebuilt in the
> [mttp repository](https://github.com/gaato/mttp). The packages arrive one
> at a time: the vocabulary, the runtime ports, their in-memory doubles,
> the HTTP/1.1 codec, the client and server connection engines and the test
> driver are here.

Sockets, TLS, an event loop and content codings live in
[`gaato/http-async`](https://mooncakes.io/docs/gaato/http-async), and the
client with retries, cookies and endpoints lives in
[`gaato/mttp`](https://mooncakes.io/docs/gaato/mttp).

## Install

```sh
moon add gaato/http
```

## Usage

Values are immutable: each builder returns a copy.

```mbt check
///|
test "describe a request" {
  let request = @http.Request::post("https://api.example.com/v1/items")
    .query("dry_run", "true")
    .bearer("token")
    .body_json({ "name": "first" })
  assert_eq(request.url, "https://api.example.com/v1/items?dry_run=true")
  assert_eq(request.headers.get("content-type"), Some("application/json"))
  assert_false(@http.is_idempotent(request))
  let url = @http.Url::parse(request.url)
  assert_eq(url.host, Some("api.example.com"))
  assert_eq(url.query_params(), [("dry_run", "true")])
}
```

A transport implements `Backend`: it sends one exchange and returns the
response head with a body the caller reads or closes. It refuses an invalid
request before any I/O, and every failure is a `TransportError` whose phase
says how far the exchange got, so `is_unsent` tells whether resending a
non-idempotent request is safe. `SendOptions` says whether the caller reads
the whole body inside the attempt (`Exchange`, with a byte limit) or streams
it (`Stream`, with an idle limit per read).

```mbt check
///|
/// Answers every request in memory, as a test double would.
struct Canned {
  status : Int32
}

///|
impl @http.Backend for Canned with fn send(self, request, options) {
  request.validate()
  options.validate()
  @http.Response::new(self.status, body=Bytes(b"ok"))
}

///|
test "send through a backend" {
  let backend : &@http.Backend = Canned::{ status: 200, }
  // `send` is async; a plain test drives it on the experimental driver.
  let response = @driver.run_sync(() => {
    backend.send(@http.Request::get("/ping"), @http.SendOptions::default())
  })
  assert_eq(response.status, 200)
  backend.close()
}
```

Stream bodies are pulled through `BodyStream` and taken once: a sender that
may send a body twice asks `Body::is_replayable` first.

## Packages

| Package | Status | What it is |
|---|---|---|
| `gaato/http` | stable | The vocabulary above, `Backend` and `SendOptions`, URL, form and HTTP-date helpers |
| `gaato/http/h1` | stable | The sans-IO HTTP/1.1 codec: bounded head and chunked decoders, strict head parsers returning `ParsedRequest` and `ParsedResponse`, body framing that refuses request smuggling, and wire writers |
| `gaato/http/rt` | stable | The ports a runtime provides: `Clock`, `Timer`, `Gate`, `Conn`, `Dialer`, `Signal`, `Coordination`, and `default_random` |
| `gaato/http/sim` | stable | In-memory doubles of the ports on the driver (`pair`, `ScriptedConn`, `FakeClock`, ...), the shared contract checks every port implementation passes, and property-test generators. Test infrastructure |
| `gaato/http/h1client` | experimental | The HTTP/1.1 client connection engine over the `rt` ports: a per-origin connection pool, connection caps, bounded heads and bodies, per-phase deadlines and HTTP proxies (CONNECT tunnels, NO_PROXY), as an `@http.Backend` |
| `gaato/http/h1server` | experimental | The HTTP/1.1 server connection engine over the `rt` ports: `serve_conn` owns one accepted connection, with bounded heads, bodies, read-ahead, draining and phase deadlines |
| `gaato/http/driver` | experimental | A deterministic task driver with virtual time and `run_sync`, so async code is tested with plain `test` blocks on every target. It is built on compiler intrinsics and may break with a toolchain change |

An experimental package is imported by listing it, as in
`options("allow-experimental-packages": ["gaato/http/driver"])` in the
importer's `moon.pkg`.

The root package's default alias `@http` is also that of
`moonbitlang/core/async/http`. A package that imports both renames one of
them, as in `"moonbitlang/core/async/http" @corehttp`.

## License

Apache-2.0

# gaato/mttp

Sans-IO HTTP for [MoonBit](https://www.moonbitlang.com/), with the split of
responsibilities of Scala's [sttp](https://sttp.softwaremill.com/) family: a
wire vocabulary (requests, responses, headers, bodies), a client that owns
retries, rate limits and deadlines, server-sent events and multipart bodies,
and deterministic test doubles. The 0.1.0 release also includes endpoint
descriptions with server and client interpreters, a router and OpenAPI
documents, in the style of [tapir](https://tapir.softwaremill.com/).

It does no I/O itself. Code written against it takes a backend, a clock and a
source of randomness from the caller, so the same code runs in production and
in a test that controls time. It depends on nothing but `moonbitlang/core`
and runs on wasm-gc, wasm, js and native.

> **Status**: early 0.x. The packages below are being moved here from
> `gaato/http`, `gaato/http-async` and `gaato/sdk-runtime`. Minor releases may
> contain breaking changes; the
> [changelog](https://github.com/gaato/mttp/blob/main/mttp/CHANGELOG.md)
> lists each one.

## Install

```sh
moon add gaato/mttp
```

## Usage

Describe a request without opening a connection, then send it through one
`Client`. Buffered and scoped streaming requests use the same executor.

```mbt check
///|
/// Reads JSON while retaining HTTP and decoding failures as values.
pub async fn fetch_json(
  client : @client.Client,
  url : String,
) -> Result[Json, @client.ResponseFailure] {
  @client.get(url).response(@client.as_json_value()).send(client).body
}
```

Built-in readers return `Result` for rejected HTTP responses and decoding
failures. `ResponseFailure` keeps the received head and at most 1 MiB of
diagnostic bytes. Transport failures raise `TransportError`; cancellation and
unknown callback exceptions propagate. The default buffered body limit is
64 MiB. Streaming callbacks own their response only until the callback ends.

Use `gaato/mttp-net.new_client()` for a ready platform client, or inject a
`Backend`, `Clock` and optional `Timer` into `Client::new`. Retries are disabled
by default. An opt-in policy is constrained by retry count, replayable body
source and remaining time. A method or explicit `replay_safe` statement must
establish idempotency; an `Idempotency-Key` header alone does not.

A configured total deadline requires a `Timer` and covers admission, retries,
backoff and stream processing. Expiry starts cancellation; required cleanup
may finish afterwards. Custom rate limiters must complete release or safely
roll back if cancellation interrupts it.

## Packages

Every package below ships in 0.1.0. Experimental packages may change in a
patch release; the others can change in a minor release while the API is 0.x.

| Package | Release | What it is |
|---|---|---|
| `gaato/mttp/clock`, `clock/fake` | 0.1 | The `Clock`, `Timer` and `Gate` traits, and fake clocks for tests |
| `gaato/mttp/jsonkit` | 0.1 | JSON field helpers: presence, object builders, open enums |
| `gaato/mttp/model` | 0.1 | Methods, headers, URLs, requests, responses, bodies and transport errors |
| `gaato/mttp/sse` | 0.1 | An incremental server-sent events parser |
| `gaato/mttp/multipart` | 0.1 | A `multipart/form-data` writer |
| `gaato/mttp/client` | 0.1 | The `Backend` trait and the `Client`: retries, rate limits, deadlines, pagination |
| `gaato/mttp/testing` | 0.1 | Backend stubs and contract checks |
| `gaato/mttp/testing/driver` | 0.1, experimental | A deterministic task driver with virtual time and `run_sync`; built on compiler intrinsics, so it may break with toolchain changes |
| `gaato/mttp/cookie` | 0.1 | An RFC 6265 cookie jar and its client wrapper |
| `gaato/mttp/h1` | 0.1 | A sans-IO HTTP/1.1 codec |
| `gaato/mttp/schema`, `endpoint`, `router` | 0.1, experimental | Endpoint descriptions, their server and client interpreters, and a router |
| `gaato/mttp/apispec`, `openapi` | 0.1, experimental | An OpenAPI 3.1 model and documents generated from endpoints |

Sockets, the event loop and content decoding live in a sibling module,
`gaato/mttp-net`, so a program that only describes requests pulls no runtime
into its dependencies.

## Links

- [Changelog](https://github.com/gaato/mttp/blob/main/mttp/CHANGELOG.md)
- [Repository](https://github.com/gaato/mttp)

## License

Apache-2.0

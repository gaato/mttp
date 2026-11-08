# Typed endpoints (experimental)

An endpoint describes request inputs, response representations and declared
errors. The same definition creates a client request, a server interpreter and
documentation metadata. This API is experimental in 0.1.x.

```mbt check
///|
test "endpoint definition and client encoding" {
  let item = @endpoint.endpoint
    .get("/items/{id}")
    .input(
      @endpoint.pair(
        @endpoint.path("id", @schema.string),
        @endpoint.query("verbose", @schema.bool).optional(),
      ),
    )
    .output(@endpoint.text_out())
    .operation_id("readItem")
  assert_eq(item.doc().problems(), [])
  assert_eq(
    item.request((), ("a/b", Some(true))).raw().url,
    "/items/a%2Fb?verbose=true",
  )
}
```

Security inputs are decoded and authenticated before regular input failures
are returned. Head decoding does not read the body. Buffered inputs are bounded
by the router limit (1 MiB by default); streamed inputs count bytes while the
handler reads. A raw signature body is buffered before authentication and
cannot be combined with a streamed regular input.

The endpoint override replaces the dispatch default; an adapter's hard body
ceiling still applies, so the smaller limit wins. Adapter `TooLarge` failures
retain their original limit. Direct dispatch defaults to problem responses:
400 for malformed inputs and validation issues, 401 for security credentials,
413 with `Connection: close` for size, and 415 for media type. Query decoding
admits 256 pairs; at most 100 failures or nested validation issues are reported.

`Body::Empty` means absent, before media-type validation. Both optional buffered
and streamed bodies decode it as `None`, even if a Content-Type was supplied.
Present zero-length bytes or streams need the declared media type and decode
as a present value. `stream_body().optional()` therefore round-trips the
bodyless request its client interpreter builds.

`serve` takes authentication and business handlers returning `Result`. Declare
ordinary application error values with `.errors(one_of([...]))`; raised errors
use the server's unhandled-error policy. These Result wrappers do not change
the wire JSON or generated OpenAPI document.

`request(...).send(client)` reads a buffered output and returns
`Result[Result[O, E], ResponseFailure]` in the reply body. A stream-only output
requires `stream_request(..., use_)` through the same send pipeline. It also
supports buffered outputs. The callback runs once, after retry decisions,
and its borrowed streams close when it exits. `call` and `call_with` are
convenience forms. `EventStream.each` closes on EOF, failure or cancellation.
SSE outputs share `sse.SseReader` with `client.as_sse`: queued complete events
are delivered before an oversized event fails, and pending overflow is raised
before another read, even when the peer goes quiet.

`path` captures one decoded segment. `paths` captures the final `{name...}`
tail as an array, retaining empty segments and encoded slashes. A custom
`Input::new` supplies its own atoms, staged decoder and inverse encoder;
`Staged::ready`, `Staged::after_body` and `RequestSink` setters are public.
Custom atoms must describe every request field their decoder consumes.

Matching buffered output variants are tried first, then matching declared-error
variants, in declaration order within each group. The Client buffers the body
once within its response limit and reuses those bytes for every candidate.
The first successful decode wins; if all fail, `Deserialization` retains the
last output failure (or the last declared-error failure if no output matched).
An unmatched status or media type yields `UnexpectedStatus`.

`query_list` embeds its item schema through `Schema.reference`, preserving
named children, reachable definitions and definition problems for the shared
definition checker.

Projection functions used by `Variant::contramap` must be deterministic:
selection and encoding may call a projection separately. `and_status` returns
the received status alongside
the typed value; `body_out` carries a per-response content type and bytes.
`set_cookie` keeps separate Set-Cookie fields and returns each named cookie's
value and attributes without interpreting its application-specific contents.

The router and `endpoint/testkit` arrive in follow-up changes. Until then,
`ServerEndpoint::dispatch` accepts captures and a `DispatchContext`; a
`@client.from_handler` backend can connect the two interpreters in memory.

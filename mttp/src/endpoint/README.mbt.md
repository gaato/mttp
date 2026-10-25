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

`serve` classifies authentication and handler errors through `Errors`; an
unclassified error uses the server policy. `call` reads a bounded buffered
response. `call_with` owns streaming results only for the callback's lifetime,
outside the client's retry loop. `EventStream.each` closes its source on EOF,
failure or cancellation.

`path` captures one decoded segment. `paths` captures the final `{name...}`
tail as an array, retaining empty segments and encoded slashes. A custom
`Input::new` supplies its own atoms, staged decoder and inverse encoder;
`Staged::ready`, `Staged::after_body` and `RequestSink` setters are public.
Custom atoms must describe every request field their decoder consumes.

Output unions try buffered decoders in declaration order. Projection functions
used by `Variant::contramap` must be deterministic: selection and encoding may
call a projection separately. `and_status` returns the received status alongside
the typed value; `body_out` carries a per-response content type and bytes.
`set_cookie` keeps separate Set-Cookie fields and returns each named cookie's
value and attributes without interpreting its application-specific contents.

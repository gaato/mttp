# Typed endpoints

An endpoint describes request inputs, response representations and declared
errors. The same definition creates a client request, a server interpreter and
documentation metadata.

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
before another read, even when the peer goes quiet. On the server, an SSE
response carries `@mttp.close_on_shutdown`, so it ends when the server shuts
down instead of holding the shutdown for its drain time; clients reconnect
with `Last-Event-ID`.

`sse_out` writes each value's JSON as the event's `data`. Its `meta` mapping
gives each value an `id`, an event name and a `retry` hint as an `SseMeta`.
A client reads them back with `EventStream::next_item` or `each_item`, which
deliver an `SseItem` holding the value beside those fields; an unnamed event
has the name `""`, as in `SseMeta::new()`. An item's `id` is the stream's last
event ID, the value to send back with the `last_event_id()` input to resume.
`next` and `next_item` pull one event at a time and return `None` from the end
on. A stream closes itself at the end, on failure and on cancellation; to stop
earlier, call `close` (a stream borrowed by `call_with` also closes when the
callback returns). Values a handler returns from `from_pull` or `from_array`
carry no fields of their own: on the server, `meta` decides them.

```mbt check
///|
test "SSE event ids resume a stream" {
  let events = @endpoint.endpoint
    .get("/events")
    .input(@endpoint.last_event_id())
    .output(
      @endpoint.sse_out(@schema.jint, meta=n => {
        @endpoint.SseMeta::new(id="\{n}", event="tick")
      }),
    )
  let server = events.serve_public(last => {
    let start = match last {
      Some(id) => @schema.int.decode(id)
      None => 0
    }
    Ok(@endpoint.EventStream::from_array([start + 1, start + 2, start + 3]))
  })
  let client = @client.Client::new(
    @client.from_handler(request => {
      server.dispatch(request, Map([]), @endpoint.DispatchContext::new())
    }),
    @sim.FakeClock::new(),
  )
  @driver.run_sync(() => {
    // Read one event, stop, and resume after it.
    let last = events
      .call_with(client, (), None, stream => {
        let item = stream.next_item().unwrap()
        assert_eq(item, @endpoint.SseItem::new(1, id="1", event="tick"))
        item.id
      })
      .unwrap()
      .unwrap()
    let rest = []
    events
    .call_with(client, (), last, stream => stream.each(n => rest.push(n)))
    .unwrap()
    .unwrap()
    assert_eq(rest, [2, 3, 4])
  })
  client.close()
}
```

`path` captures one decoded segment. `paths` captures the final `{name...}`
tail as an array, retaining empty segments and encoded slashes. A custom
`Input::new` supplies its own atoms, staged decoder and inverse encoder;
`Staged::ready`, `Staged::after_body` and `RequestSink` setters are public.
Custom atoms must describe every request field their decoder consumes.
`encoded_path_template` exposes the same literal encoding used by client
requests, retaining capture placeholders for documentation. Dot-only literal
segments are refused along with dot-only capture values, because transports
normalize them. `media_type_token` exposes the media comparison used by body
inputs and response matching: case-insensitive, without parameters.

`raw_body()` requires a present body without restricting its media type;
`raw_body().optional()` accepts absence. Present zero-length bytes remain
present. Raw security may share buffered bytes with a typed regular body.

`check_definitions` requires equivalent path templates to use the same capture
names at each position, even for different methods. For example, GET
`/pets/{id}` and DELETE `/pets/{name}` are refused: OpenAPI would otherwise
contain two forbidden aliases for the same hierarchy. Use `/pets/{id}` for
both methods. Single and rest captures use the same naming rule when their
paths project to the same OpenAPI hierarchy; distinct literal paths remain
independent.

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

Serve endpoints through `gaato/mttp/router`, and stub them in tests with
`gaato/mttp/endpoint/testkit`. `ServerEndpoint::dispatch` remains for adapters
that route themselves: it takes the captures and a `DispatchContext`.

Each endpoint documents the errors its own output declares. Shared error
types are fine, but give each endpoint an `Out` with only the variants it can
return, so a public route does not document 401 or 409:

```mbt check
///|
test "each endpoint declares only its own errors" {
  let not_found = @endpoint.empty_variant(404)
  let read = @endpoint.endpoint
    .get("/items/{id}")
    .input(@endpoint.path("id", @schema.string))
    .output(@endpoint.text_out())
    .errors(@endpoint.one_of([not_found]))
  let statuses = read.doc().errors.map(variant => variant.status)
  assert_eq(statuses, [404])
}
```

# gaato/mttp/sse

Server-sent events (`text/event-stream`): a parser, a reader and an encoder.

They follow the
[WHATWG HTML standard](https://html.spec.whatwg.org/multipage/server-sent-events.html#event-stream-interpretation):
an incremental parser, a shared async reader over the portable
`@mttp.BodyStream` interface, and an encoder for the server side. No runtime
adapter is required.

- `SseParser::feed` takes chunks however the transport splits them, even in
  the middle of a UTF-8 character or a CRLF, and returns the events they
  complete. Lines end at CR, LF or CRLF; a byte order mark is skipped at the
  start of the stream only; malformed UTF-8 becomes U+FFFD; comments and
  unknown fields are ignored; an `id` containing NUL is ignored.
- `SseParser::finish` ends the stream and drops an event that never got its
  blank line, as the standard says.
- `last_event_id` and `reconnection_ms` are the stream's state for the next
  connection: what to send as `Last-Event-ID` and how long the server asked
  the client to wait. Waits past one hour read as one hour.
- `encode` writes one event, refusing an event name or id that would inject
  another field.

The parser is bounded: one event, counting its `data` lines, the `event` and
`id` lines in effect and the line being read, may hold `max_event_bytes`
(16 MiB by default). Past that, `feed` raises
`@mttp.TransportError(kind=TooLarge(limit), phase=Body, ..)` and the stream
ends; events that the same chunk completed earlier are returned first and the
next call raises.

`SseReader::new(source, max_event_bytes~)` owns a body source and exposes
`next_event` for pull consumers and `each(receive, stop~)` for callbacks.
It delivers queued events before surfacing a deferred overflow, and checks
that overflow before reading again so a quiet peer cannot hide it. Each
event has the parser's byte limit; the queue holds at most the events from
one source chunk. Both `client.as_sse` and endpoint SSE outputs use this reader.

EOF, read/parse failure and cancellation during a pull close the source.
`each` also closes on callback failure or cancellation and stops before
delivering a matching sentinel. An intentional stop discards any queued
events and pending overflow. Pull consumers stopping early must call `close`;
later pulls return EOF without reading the source. As with a body stream,
use one consumer without concurrent pulls.

```mbt check
///|
test "parse an event stream split at arbitrary points" {
  let parser = @sse.SseParser::new()
  let events = parser.feed(b"retry: 1000\nid: 1\nevent: delta\ndata: hel")
  assert_eq(events, [])
  let events = parser.feed(b"lo\r\n\r\ndata: [DONE]\n\n")
  assert_eq(events.map(e => (e.event, e.data)), [
    ("delta", "hello"),
    ("message", "[DONE]"),
  ])
  assert_eq(parser.finish(), [])
  assert_eq(parser.last_event_id(), Some("1"))
  assert_eq(parser.reconnection_ms(), Some(1000))
}

///|
test "encode an event" {
  let event : @sse.SseEvent = {
    event: "delta",
    data: "two\nlines",
    id: Some("2"),
    retry: None,
  }
  assert_eq(
    @sse.encode(event),
    b"event: delta\nid: 2\ndata: two\ndata: lines\n\n",
  )
}
```

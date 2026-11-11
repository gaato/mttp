# In-process router

Router validates definitions at construction and dispatches through ordered
middleware. Literal segments beat captures, and a final rest capture is less
specific than an exact path. Once a path is selected, a method mismatch does
not fall through to a less specific route.

```mbt check
///|
test "in-process router example" {
  let endpoint = @endpoint.endpoint.get("/hello").output(@endpoint.text_out())
  let router = @router.Router::new([endpoint.serve_public(_ => Ok("hello"))])
  @driver.run_sync(() => {
    let response = router.dispatch(@mttp.Request::get("/hello"))
    assert_eq(response.body, @mttp.Bytes(b"hello"))
  })
  router.close()
}
```

An explicit HEAD endpoint wins; otherwise GET handles HEAD and its body is
closed and removed. OPTIONS is generated from the selected path's methods.
Default failures use application/problem+json; internal exception details and
authentication credentials are not included. Configure `ServerOptions` to
override error policies and add middleware such as `cors`.

As a Backend, Router strips local attributes in both directions and marks the
server-side remote address as `in-process`. Streaming bodies pass through
without buffering. Closing a router refuses new requests while already returned
response streams remain usable.

The in-process Backend validates `SendOptions`, preflights a streamed upload's
first chunk, and enforces `Exchange(max_bytes)` without buffering streamed
responses. Supply `clock` and `timer` ports to `Router::new` for positive
attempt or idle deadlines. Without both ports, timed sends fail as `Invalid`
before dispatch. A whole-exchange deadline includes elapsed head time and
caller pauses before reading; a streaming head deadline ends at the head.

Templates and request paths have at most 64 segments, including empty request
segments. Excess template depth is a fatal definition problem; an excess
request is a 404. `check_definitions(docs, adapter_max_body_bytes=ceiling)`
reports endpoint body overrides above a known adapter ceiling as advisories;
the adapter's stream enforces that ceiling. The same optional ceiling can be
given to `Router::new` for checking. It does not replace the real adapter cap.

`hide_endpoints_with_auth` is a decode-failure preset that returns 404 for
failed authentication inputs. `request_id` forwards and echoes X-Request-ID,
generating a diagnostic ID when absent, empty or repeated. `access_log` calls
its sink with the request head, response metadata and elapsed milliseconds at
the response head; it does not wait for a stream to finish. Its clock and the
request-ID generator can be injected for deterministic tests.

`cors` varies every explicit-allowlist response on Origin, including missing,
denied and repeated origins, and preserves existing Vary fields. Wildcard
responses without credentials always carry `Access-Control-Allow-Origin: *`.
OPTIONS responses also vary on the preflight method and headers before any
early return, so missing headers cannot prime a different preflight result.

Middleware owns resources it creates until it calls `next` with them. Each
handler boundary then owns its incoming request body, including a replacement
body supplied upstream. Buffered responses, short-circuits and cancellation
close that body. A streamed response retains it until EOF, close, failure or
cancellation, because lazy middleware and custom rejection handlers may still
read it after returning the head.

Router also closes an inner response that middleware replaces without taking
its reader. Taking an inner response stream transfers its ownership to
middleware: a lazy wrapper must close that reader on completion, failure or
cancellation, and middleware must close any taken reader it discards. Every
call to `next` owns the body passed to that call, even if an inner middleware
returns without routing it.

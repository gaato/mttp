# gaato/mttp/router

Path and method dispatch for server endpoints, with middleware and server policy.

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

## Serving

`Router::handler()` is the `async (@mttp.Request) -> @mttp.Response` that a
server runs: pass it to `gaato/mttp_async`'s `@server.serve`, or to
`@fetch.fetch_handler` for a JavaScript `fetch` export. `Router::new` raises
a `DefinitionError` for definitions it refuses; `Router::must` aborts
instead, so a router can be a top-level `let`.

Requests and responses carry `@mttp.Attributes`: typed local metadata that is
never sent. When a server shuts down, it lets running responses finish, but
closes a streamed response whose `@mttp.close_on_shutdown` attribute is true
instead of draining it. That is for endless streams such as server-sent
events, whose clients reconnect; `@endpoint.sse_out` and `sse_body_out` set
it.

## Routing

An explicit HEAD endpoint wins; otherwise GET handles HEAD and its body is
closed and removed. The GET handler runs in full for such a HEAD request, so a
GET with side effects (a hit counter, say) sees HEAD requests too; declare a
HEAD endpoint to answer them separately. OPTIONS is generated from the selected path's methods.
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

A response to an allowed origin carries `Access-Control-Expose-Headers` with
the names in `expose_headers` and the response headers the answering
endpoint declares (`and_header`, `fixed_header`), so a typed client on
another origin can read an `ETag` it expects without extra configuration.
Repeats are dropped without regard to case, and CORS-safelisted headers such
as `Content-Type` are left out because browsers expose them anyway. Preflight
responses carry none: browsers read the list only from the actual response.

## Cross-site request forgery

An app with forms and a cookie session should add `same_origin` and set its
session cookie `SameSite=Lax` (or `Strict`). The middleware follows OWASP's
Fetch Metadata and Origin verification, with no tokens or session state.
GET, HEAD, OPTIONS and TRACE pass untouched, so keep them free of side
effects. Any other method is refused with a 403 problem+json, before its
handler runs, when the browser marks it as coming from elsewhere:

| `Sec-Fetch-Site` | `Origin` | Result |
|---|---|---|
| `same-origin` or `none` | any | allowed |
| `same-site`, `cross-site`, repeated or unknown | in `allowed_origins` | allowed |
| `same-site`, `cross-site`, repeated or unknown | anything else or absent | 403 |
| absent | absent (curl, SDKs and other non-browser clients) | allowed |
| absent | the request's own origin, or in `allowed_origins` | allowed |
| absent | anything else, `null` or repeated | 403 |

The request's own origin is the scheme, host and port of the absolute request
URL that `h1server` (its `scheme` and the `Host` field) and `fetch` build;
a relative URL has none. Behind a proxy that terminates TLS that URL says
`http`, so list the public `https` origin in `allowed_origins` for browsers
that predate `Sec-Fetch-Site`. List other origins, such as a separate
front-end, the same way, exactly as browsers send them; `null` never matches.

```mbt check
///|
test "same-origin protection" {
  let post = @endpoint.endpoint.post("/notes").serve_public(_ => Ok(()))
  let router = @router.Router::new([post], options={
    ..@router.ServerOptions::default(),
    middleware: [@router.same_origin()],
  })
  @driver.run_sync(() => {
    let form = @mttp.Request::post("https://notes.example/notes")
    let forged = form.header("sec-fetch-site", "cross-site")
    assert_eq(router.dispatch(forged).status, 403)
    let own = form.header("sec-fetch-site", "same-origin")
    assert_eq(router.dispatch(own).status, 200)
  })
  router.close()
}
```

This protects against requests a browser sends from another site with the
user's cookies. It does not authenticate anything: a non-browser client can
send any header, and script injected into the app itself (XSS) runs as the
same origin.

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

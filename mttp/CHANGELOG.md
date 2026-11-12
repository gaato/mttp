# Changelog

All notable changes to `gaato/mttp` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

### Changed

- OpenAPI documents describe each server-sent event in OpenAPI 3.2's item
  shape, under the media type's `x-oai-itemSchema` extension, instead of
  `x-mttp-sse-data-schema` inside the schema. The documents stay OpenAPI 3.1.
  `VariantDoc` gains `item_schema`.
- gaato/http is now part of gaato/mttp. Its vocabulary (`Request`, `Response`,
  `Body`, `Backend` and the rest) is the root package, `@mttp`, and `h1`, `rt`,
  `sim`, `driver`, `h1client` and `h1server` are `gaato/mttp/...`. Replace
  `gaato/http` with `gaato/mttp` in moon.mod and moon.pkg, and `@http.` with
  `@mttp.` in code. gaato/mttp no longer depends on any module.
- The endpoint layer (`endpoint`, `endpoint/testkit`, `router`, `apispec`,
  `openapi`) and the connection engines (`h1client`, `h1server`) are no longer
  experimental: importers drop them from `allow-experimental-packages`. Only
  `driver` stays experimental, because it relies on the compiler's `%async`
  intrinsics.
- `apispec` accepts what OpenAPI allows: an operation without `responses`
  (optional since 3.1) and, for 3.2, a response without `description`.
  `Operation::new` takes `responses~` (default empty) and `ResponseObject::new`
  takes `description?`; the 3.1 documents `openapi` emits still always describe
  each response.
- `@schema.pattern` no longer raises: an unsupported pattern is recorded as a
  definition problem, which the endpoint definition check reports as a
  `DefinitionError`, so validators compose in top-level definitions.
  `UnsupportedPattern` is no longer public.
- `sse_out` takes `meta : (T) -> SseMeta` instead of
  `to_event : (T) -> @sse.SseEvent`. The library always writes the codec's
  JSON as an event's `data`, so setting an `id`, event name or `retry` no
  longer means building the whole event; replace
  `to_event=v => @sse.SseEvent::{ data: ..., id: Some(x), .. }` with
  `meta=v => SseMeta::new(id=x)`; for data that is not JSON, such as HTML,
  use `sse_body_out`.
- An event stream from `sse_out` or `sse_body_out` opens with an SSE comment
  line (`:` and a blank line) before its first event, so every server sends
  the response head at once instead of when the first event exists: a
  browser's `onopen` fires, a proxy does not time out an idle stream, and on
  Deno, Bun and Node `shutdown()` ends a stream that has no event yet. SSE
  parsers ignore the comment, so typed clients and `EventSource` read the same
  events.
- An event that an event stream cannot encode (an `id` with a line break,
  data that is not UTF-8) ends it with that `Invalid` error instead of
  `event source failed`, which stays the error for a failing producer.
- `@client.read_body` moved to the root package as
  `Body::read_all(max~)`, so a server handler can read a request body within
  a limit without the client package. Its behaviour is unchanged: a body over
  the limit raises `TooLarge`, a negative limit `Invalid`, and a stream is
  closed in every case. Replace `@client.read_body(body, limit)` with
  `body.read_all(max=limit)`.
- Redirects and cookies are Client policies, like retries and deadlines, so
  they work over any backend, a test stub included. `Client::new` takes
  `redirect~ : RedirectConfig` (default `RedirectConfig::default()`, up to
  10 hops) and `cookies? : CookieJar`, and wraps its backend as
  `FollowRedirects(Cookies(backend, jar))`: the hops of one attempt share its
  admission and deadline, and a retry starts again from the original request.
  A Client over a stub that answers 3xx now follows it; pass
  `redirect=RedirectConfig::none()` (new) to get the 3xx back, or
  `.follow_redirects(false)` for one request. A stack built by hand that
  already contains `FollowRedirects` passes `redirect=RedirectConfig::none()`
  too, and drops its own `Cookies` in favour of `cookies=` unless it needs
  another order.

### Added

- `RetryBudget`: a Client caps its retries at a share of recent requests (by
  default 20 % of the requests of the last 10 s plus 10 per second), so the
  callers of a failing server do not multiply its load. `Client::new` takes
  `retry_budget` and uses `RetryBudget::new()` by default; a refused retry stops
  with the new `StopReason::RetryBudgetSpent`. `RetryBudget::unlimited()` leaves
  the decision to the retry policy.
- `apispec` types the fields OpenAPI 3.2 adds: `OpenApi.self_` (`$self`),
  `Server.name`, `Tag.summary`, `parent` and `kind`,
  `MediaTypeObject.item_schema` (`itemSchema`), `ResponseObject.summary`,
  `SecurityScheme.deprecated` and `oauth2_metadata_url`,
  `Components.media_types`, and `PathItem`'s `query` operation and
  `additional_operations`. They stay unset in the 3.1 documents `openapi` emits.
- `Show` for the error types (`TransportError`, `UrlError`, `InvalidRequest`,
  `ResponseFailure`, `DecodeFailure`, `DefinitionError`, `InputErrors`,
  `ServerConfigError`), so they interpolate as readable messages;
  `reason_phrase` covers every status code RFC 9110, 6585 and 7725 register.
- `SseMeta`, `SseItem` and `EventStream::next`, `next_item` and `each_item`: a
  client reads each typed event's `id`, event name and `retry` beside its
  value, so it can resume with the `last_event_id()` input, and pulls events
  one at a time, so it can stop before the end and `close` the stream.
- `close_on_shutdown`, a response attribute: a streamed response with it set
  to true is closed when the server starts to shut down instead of being
  drained, for endless streams such as server-sent events, whose clients
  reconnect. `h1server.serve_conn` cuts such a stream once `stopping` holds,
  also while its producer waits (asking `stopping` every 250 ms then): it
  closes the body, ends a chunked body with its last chunk and closes the
  connection. Its producer is not bound by `body_timeout_ms`, so an event
  stream may stay silent until its next event; writes to the client keep
  that deadline. `endpoint.sse_out` sets it on the responses it builds.
- `Router::must`: `Router::new` for definitions known to be right, such as a
  top-level `let` in an app or a JavaScript entry, where an error cannot be
  raised; a definition problem aborts with the problems.
- `schema.html_body`, `endpoint.html_out` and `endpoint.html_variant`: an
  HTML page as `text/html; charset=utf-8`. The handler renders the page and
  returns the string, so a client reads back the same string. An error page is
  `errors(html_out(status=404))`; `html_variant` puts a page in `one_of`, so
  one URL can answer htmx with a fragment and a plain form post with a 303.
- `sse_body_out(codec, meta?)`: an event stream whose `data` is a
  `BodyCodec`'s encoding as UTF-8 text, decoded with the same codec on a
  client. For htmx's SSE extension, `sse_body_out(@schema.html_body, meta=...)`
  sends HTML fragments as they are, where `sse_out` would send each as a JSON
  string. An encoding that is not UTF-8 ends the stream with a
  `TransportError` of kind `Invalid`; line breaks become several `data` lines,
  which a client joins with LF. `sse_out(codec, meta?)` is
  `sse_body_out(codec.body(), meta?)` and writes the same events as before.
- `EventStream::map`: a stream of converted events that keeps each event's
  `id`, event name and `retry`, for example to turn typed rows into the HTML
  strings that `sse_body_out(@schema.html_body)` sends to htmx.
- Router middleware `same_origin(allowed_origins?)` refuses state-changing
  requests that a browser sends from another site, by `Sec-Fetch-Site` and,
  for browsers without it, `Origin`, with no tokens or session state. Use it
  with `SameSite` cookies in apps with forms and a cookie session.
- `@schema.form_codec(codec)` reads and writes an
  `application/x-www-form-urlencoded` body with an object `JsonCodec`, so an
  HTML form and a JSON API share one definition, its validation and its
  JSON-pointer issue paths. Values are coerced by their property's schema type
  (a checkbox's `on` is `true`; an absent required boolean is `false` and an
  absent required array `[]`), text that does not coerce is an issue at the
  property's pointer, and a property that is not a scalar or an array of scalars
  is a definition problem. Use it with `@endpoint.body`.
- `format_http_date(unix_ms)` writes an IMF-fixdate (RFC 9110 §5.6.7) for
  `Date`, `Last-Modified`, `Expires` or a cookie's `Expires`, the counterpart of
  `parse_http_date`; times outside the years 1 to 9999 are clamped.
- `Endpoint::serve_with` and `serve_public_with`: like `serve` and
  `serve_public`, and the handler also receives the attributes of the request
  being served (`@mttp.remote_addr`, the `@mttp.background` scheduler), so a
  definition shared with clients stays the wire contract instead of gaining an
  `attribute(...)` input that would also appear in the client's input type.
- `EventStream::channel(coordination~, capacity~)` with `EventSender::send`,
  `close` and `fail`: a bounded channel from a producer that pushes, such as
  an SDK's streaming callback, to a stream that `sse_out` writes. `send`
  waits while `capacity` values (16 by default) are queued and returns `false`
  once the reader closed the stream (a client disconnected), so the producer
  can cancel its upstream call; `fail` ends the stream with an error, so a
  client does not take a failed producer's output for a complete stream.
- `cors` takes `expose_headers` and, for an allowed origin, also exposes the
  response headers the answering endpoint declares, which it reads from the
  new `endpoint.declared_headers` response attribute. A browser on another
  origin could not read a declared `ETag` before, so mttp's typed client there
  failed with "missing header" even on success. CORS-safelisted headers are
  left out, and preflight responses expose nothing.
- `@schema.omittable(codec)`: an object field that may be left out but not
  set to null. Absent decodes to `None` and `None` is omitted; null is refused
  with the child codec's issue at the field's path, and the schema is the
  child's, not nullable, so OpenAPI no longer shows such a field as nullable
  the way `option` does.

## [0.1.0] - 2026-11-10

### Added

- First release: a client on `gaato/http.Backend` with retries, rate limits,
  deadlines, redirects and cookies; typed response readers, server-sent
  events and multipart; schemas, endpoints, a router and OpenAPI; test stubs.

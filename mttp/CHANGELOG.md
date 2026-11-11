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
  `meta=v => SseMeta::new(id=x)`.

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
  connection. `endpoint.sse_out` sets it on the responses it builds.
- `Router::must`: `Router::new` for definitions known to be right, such as a
  top-level `let` in an app or a JavaScript entry, where an error cannot be
  raised; a definition problem aborts with the problems.
- `schema.html_body`, `endpoint.html_out` and `endpoint.html_variant`: an
  HTML page as `text/html; charset=utf-8`. The handler renders the page and
  returns the string, so a client reads back the same string. An error page is
  `errors(html_out(status=404))`; `html_variant` puts a page in `one_of`, so
  one URL can answer htmx with a fragment and a plain form post with a 303.
- `EventStream::map`: a stream of converted events that keeps each event's
  `id`, event name and `retry`, for example to turn typed events into HTML
  rows for htmx's SSE extension.

## [0.1.0] - 2026-11-10

### Added

- First release: a client on `gaato/http.Backend` with retries, rate limits,
  deadlines, redirects and cookies; typed response readers, server-sent
  events and multipart; schemas, endpoints, a router and OpenAPI; test stubs.

# Changelog

All notable changes to `gaato/mttp_core` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

## [0.2.0] - 2026-11-17

### Added

- `client.ReconnectPolicy` and `ReconnectDecision`: when to reconnect a
  long-lived stream, as data (`decide`, `next_attempts`; default 1 s to 30 s
  with jitter, unlimited, count reset after a connection that lived 60 s,
  server `retry:` honoured within the cap), for event streams and an
  application's own WebSocket loop.
- `Client::sse_reconnecting`: the `EventSource` loop over `@sse.SseReader`,
  resending with `Last-Event-ID`, waiting per the policy and the stream's
  `retry:` (or `Retry-After`), stopping on 204 and on statuses other than
  408, 429 and 5xx; it returns an `SseEnd` (`SseDisconnect` for the last end
  when it gives up). `SseReader::last_event_id` and `reconnection_ms` expose
  the reader's stream state.
- `client.CircuitBreaker`: a per-origin circuit breaker Backend wrapper
  (failure ratio over a window, open time, half-open probes; at most
  `max_origins` circuits, least recently used evicted), refusing with the
  new `Kind::CircuitOpen` in phase Pool, which the retry rules never retry.
- `client.AuthRefresh`: a Backend wrapper that refreshes credentials once on
  401, shared by concurrent 401s through an `rt.Signal`, and resends a
  replayable request once, marked with the `auth_refreshed` attribute.
- Observability, opt-in: `client.Client::new(events?)` receives every
  `client.ClientEvent` (`AttemptStart`, `Phase`, `AttemptEnd`, `Retry`,
  `Redirect`) in order, beside the unchanged `observer`; nothing about an
  attempt follows its `AttemptEnd`, cancellation included. Backends report
  `PhaseEvent`s (`Dialed`, `TlsDone`, `Pooled`, `Written`, `FirstByte`) to
  the new `on_phase` request attribute, in order and once each
  (CONTRACT.md, Backend rule 13); `SendOptions` is unchanged. h1client
  reports all five. The client README maps the fields onto OpenTelemetry's
  HTTP semantic conventions.
- `client.trace_context(backend, generate~)` adds a W3C `traceparent` to
  requests that have none and records the trace id under `client.trace_id`.
- `client.redact_headers(headers, names~)` hides credential values for
  logging, by default those in `client.default_sensitive_headers`, the list
  `to_curl` now uses too; it adds `set-cookie` to the five names `to_curl`
  hid before.
- Bounded streaming multipart/form-data reader and synchronous parser, typed
  multipart endpoint fields and file streams, and OpenAPI per-part encoding.

- Opt-in router `rate_limit` (exact sliding windows, bounded LRU keys and
  draft-ietf-httpapi-ratelimit-headers-11 fields), `secure_headers` and signed
  cookie `sessions`, with a typed mutable `session` attribute. Signing and
  verification are caller-supplied; no crypto dependency is added. Window
  arithmetic is shared internally with the unchanged client rate limiter.
- `connection_scheme`, a request attribute: the scheme the connection was
  accepted under (`http` or `https`), never the request target's. h1server
  sets it from its `scheme`, Router-as-Backend from the in-process
  request's scheme; `connection_scheme_of` normalizes a scheme to it.
- `endpoint.WsEndpoint`, message codecs and `TypedSession`: one definition
  serves a typed handler, connects through an injected runtime connector,
  runs through Router's byte pair and pairs with a scripted peer in testkit.
  Router docs retain message schemas; OpenAPI projects the GET handshake,
  101 response, inputs, security and `x-websocket.subprotocols`.
  Portable `ws.server_handler` upgrades use each server adapter's ports.
- `openapi.docs_ui_endpoint(spec_url~, path~, ui~)` serves Scalar or Swagger UI
  with pinned CDN assets, SHA-384 integrity and a restrictive CSP.
- `openapi.to_openapi(version=V3_2)` emits OpenAPI 3.2.0 with SSE `itemSchema`;
  the default remains 3.1.0 with `x-oai-itemSchema`.
- `schema.object9` through `object16` support larger typed object codecs.
- `h1client.Client::new(max_connection_age_ms?)` optionally expires parked
  connections by total age, independently of idle time. Default off (`None`)
  preserves existing behavior; zero or less prevents reuse, active exchanges
  continue. No field is added to the frozen `ClientConfig`: keep building it
  with `{ ..ClientConfig::default(), ... }` and pass the age to `new`.
- `h1client.ProxyConfig`: `socks5h://` proxy DNS with bounded RFC 1928 CONNECT
  and RFC 1929 username/password negotiation, environment selection and
  NO_PROXY bypass, followed by TLS for HTTPS. `socks5://` remains refused
  with a clear remote-DNS alternative until a resolver port exists.
- Router's in-process WebSocket backend hands over the byte connection when
  an extension is negotiated, allowing the caller to install its extension
  while keeping compression outside mttp_core.
- WebSocket sessions abort after a transformed message is rejected or its
  queued send is cancelled, so stateful extensions cannot reuse unsent history.

- `h1server.serve_conn(on_response_complete~)` acknowledges each returned
  HTTP response after writing, body cleanup and unread-request draining,
  including failure and cancellation. Successful upgrades retain ownership
  until their callback ends instead of acknowledging an HTTP completion.

- `cache`: RFC 9111 section 4.2 as pure functions: `CacheControl::parse`,
  `freshness_lifetime`, `current_age` and `Freshness`, which says whether a
  stored response is fresh and whether RFC 5861's stale-while-revalidate
  or stale-if-error lets it be served stale.

- `dictionary`: RFC 9842's client side without I/O. `UseAsDictionary`
  reads and writes the header; `DictionaryStore` keeps the dictionaries
  fresh responses name, per partition and bounded (64 dictionaries, 4 MiB
  each, 32 MiB in all), and chooses the one a request offers as section
  2.2.3 says. The caller passes SHA-256.

- `urlpattern`: WHATWG URL patterns, `UrlPattern::parse` and
  `UrlPattern::new`, with `matches` and `matches_init`, for RFC 9842's
  `match`. Every component, named groups, wildcards and modifiers follow
  the standard; matching is an automaton run once over the input, and a
  regular expression group is refused with `RegexpGroup`. 337 of
  web-platform-tests' 369 urlpattern cases pass; of the rest, 29 need what
  is left out (regular expressions, `ignoreCase`, IDNA) and 3 a URL that
  `Url::parse` reads otherwise than WHATWG's parser.

- `sf`: RFC 9651 Structured Field Values. `parse_list`,
  `parse_dictionary` and `parse_item` take a field's lines, and
  `serialize_*` write the canonical text, both as section 4 states them;
  Decimals are exact thousandths. All 2,160 tests of httpwg's
  structured-field-tests pass in the conformance module.

- `rt.upgrade` and `ws.ws_session`: HTTP/1 server 101 connection hand-over,
  preserving read-ahead and admission until callback completion, with HTTP
  deadlines ending at the head. Router's in-process WebSocket path uses the
  real codec over a bounded byte pair and explicit scheduling ports.

- `rt.close_unclaimed(attributes)` and `rt.Upgrades` keep upgraded sockets
  owned through decoder failures, cancellation, redirects and Client/engine
  closure. Only unclaimed connections are reclaimed; take/discard removes
  retained entries immediately. A 101 from a fresh resend keeps stale_resend.

- HTTP/1 client upgrades retain their slot and read-ahead through the
  take-once `rt.Upgraded` / `rt.upgraded` hand-over.
  Unrequested 101 responses are Protocol errors in Head. Proxy upgrades use
  CONNECT. Wrappers preserve unknown attributes and never retry a 101;
  `sim.check_backend_contract(wrap~)` checks metadata preservation.

- Sans-I/O `ws/handshake`: injected 16-byte client keys, RFC accept values,
  client request and server response validation, 400/403/426 server refusals,
  same-origin policy, bounded generic extension syntax, and value-only 101
  responses ready for the later HTTP engine hand-over.
- `ws`: message-level `Session`, strict Close payloads, per-message extensions
  and a portable `session_over_conn` over rt ports. It bounds frames, wire and
  decoded messages, empty frames and waits, masks client frames with injected
  entropy, serializes senders and drives Ping/Pong and Close from one receiver.
  `sim.WebSocketStub::pair` supplies message-level sessions for in-process use.
- **Breaking for rt.Coordination implementers:** add
  `protect(work~ : async () -> Unit raise TransportError)`. It defers caller
  cancellation while bounded work finishes, retaining the cancellation for
  the next unprotected suspension. `Driver::protect` supplies nested task-local
  cancellation masks; shutdown preserves protected work's deadline timers.
  WebSocket control replies use protection; data sends cancelled mid-frame
  still fail the session and close its connection.

- `h1server.serve_conn(auto_date~ : Bool = true)` sends Date on every final
  response without one, including errors and HEAD/204/304. It uses the
  injected clock and caches IMF-fixdate per connection and second. A handler's
  Date is kept; `auto_date=false` disables insertion. Interim 100 Continue
  is unchanged.
- Seeded schedules for the driver: `Driver::new(schedule~)` and
  `run_sync(f, schedule~)` take a `Schedule` (`seeded(seed)`,
  `replay(choices)`, `choices()`), under which a task woken by an I/O event
  (`io_event`, which `SimConn` now uses for what it delivers) may be
  overtaken by tasks that became ready later at the same virtual instant.
  Any time advance, including manual control, ends that delay. Timers
  always fire in (deadline, arming) order, including equal deadlines armed
  at different instants, as on core/async; everything else stays FIFO, and
  without a schedule the order is FIFO exactly as before (CONTRACT.md,
  Driver rule 9).
- `sim.explore`: runs a scenario in FIFO order and under 32 seeds, and on a
  failure shrinks the seed's choices with delta debugging and prints the
  `Schedule::replay([..])` call that reproduces it. The `h1server` and
  `h1client` suites run their tests that meet a decision point under it.
- Sans-I/O `ws/frame`: incremental role-aware RFC 6455 frame parsing,
  bounded declared payloads, sticky close-code-mapped errors, frame-head
  encoding, piecewise masking and strict incremental UTF-8 validation.
  Internal incremental SHA-1 supports Sec-WebSocket-Accept only, not security.

- `Kind::Refused`: the peer said it did not process the request, as an
  HTTP/2 stream reset with REFUSED_STREAM or above a GOAWAY's last stream
  identifier, or HTTP/3's H3_REQUEST_REJECTED. `is_unsent` counts it, so
  the Client resends such a request whatever its method. A backend reports
  it in the phase the exchange reached instead of claiming phase Pool
  (CONTRACT.md, Backend rule 2).
- The `abandon_request_body` response attribute: the server will not read
  the rest of the request body. `h1server` ends the connection after such
  a response; the Router sets it on its 413 answers instead of writing
  `Connection: close`, a header that HTTP/2 and HTTP/3 forbid.
- The `protocol` attribute: the ALPN identifier (`http/1.0`, `http/1.1`,
  `h2`, `h3`) of the protocol that carried a message. `h1client` sets it on
  responses and `h1server` on requests (CONTRACT.md, Backend rule 11).
- CONTRACT.md, Backend rule 10: a backend sends in TLS 1.3 early data only
  requests that may be replayed.

- `Kind::IncompleteClose`: a transport ended without its own end-of-stream
  signal, as a TLS session does when its peer closes the connection beneath
  without close_notify (RFC 9112, section 9.8 calls this an incomplete
  close). `rt.Conn` reads may raise it; like EOF it is permanent
  (CONTRACT.md, Connections and coordination).

### Fixed

- OpenAPI 3.2 SSE responses omit the complete-body wire-string `schema`,
  retaining per-event `itemSchema` validation. Complete sequential content
  maps to an array in 3.2; the 3.1 projection remains unchanged.
- SOCKS5h CONNECT sends numeric IPv4 literals as ATYP 1 and IPv6 literals
  (including mapped forms) as ATYP 4 in network byte order. Only hostnames
  use ATYP 3 and proxy DNS; parsing a literal performs no DNS resolution.

- Protected WebSocket control writes use the smaller send/close deadline
  (5 s by default), bounding cancelled receiver joins when a peer stops reading.

- WebSocket Pong draining returns completed messages without waiting for a
  partial next header. Speculative read errors, including TLS IncompleteClose,
  follow all messages already buffered instead of discarding them.

- Keep Pong writes in the independent receive monitor so two backpressured
  peers continue reading while both reply to Ping. The parser waits only for
  writer dispatch or completed-I/O cleanup, preserving prompt free-writer
  replies and bounded latest-Pong coalescing while writes are blocked.

- Answer every Ping promptly when the send direction is free (Autobahn 2.10),
  retaining latest-Pong coalescing behind a blocked sender.

- OpenAPI framework Problem responses now give their `errors` array an
  unconstrained item schema, producing valid JSON Schema for external tooling.
- `apispec` now decodes OpenAPI Reference Objects wherever its typed
  parameters, request bodies and security schemes allow them, and preserves
  provider-written empty defaults when writing a decoded document back.

- Driver shutdown starts a fresh unwind round after budget exhaustion,
  even when protected cleanup keeps a timer armed. It no longer retries
  the exhausted counters indefinitely; the cleanup and unwind budgets apply.

### Deprecated

- `Response::closes_connection`: the Connection header exists only in
  HTTP/1.1, and `h1server` reads it itself. A handler that stops reading
  the request body sets `abandon_request_body`.

### Changed

- The HTTP/1 server writes a Bytes response's head and body together when
  their total is at most 4 KiB, avoiding a second write and deadline scope.
  Larger responses keep separate, bounded writes; bodiless and shutdown-cut
  responses retain their framing and completion behavior.

- HTTP/1 response readers accept three-digit statuses 600–999 as server
  failures while retaining the wire number in responses and failure values
  (RFC 9110, section 15). Retry status rules still match that number
  explicitly. Codes below 100, malformed status lines, and the server's
  outgoing status range are unchanged.
- `Headers::validate` now refuses nonempty values with leading/trailing SP
  or HTAB with `Invalid` in phase Pool, before client I/O. HTTP/1 writers
  refuse them too, including replaced framing fields; invalid handler
  response values become 500. Trim the value before setting it. Empty values
  and interior SP/HTAB stay valid.
- The Router's and the endpoint layer's 413 answers no longer carry
  `Connection: close`; they set `abandon_request_body`, which `h1server`
  turns into the same header and close.
- `h1client` and `h1server` treat `IncompleteClose` as EOF wherever the
  message framing delimits the message: response heads, a proxy's CONNECT
  answer, Content-Length and chunked bodies, every read of the server
  engine, and the resend of a request whose reused connection closed before
  the response, which happens once whether the close was clean or not. Only
  a response body delimited by the close itself (no Content-Length, not
  chunked) now fails with `Protocol` in phase Body, since it may have been
  cut short. gaato/mttp's TLS connections raise it on MoonBit toolchains
  after 0.10.20, whose core/async reports such a close where 0.10.20
  returned EOF.

## [0.1.0] - 2026-11-12

### Changed

- gaato/mttp_core is the new name of gaato/mttp 0.2.0, the HTTP library
  without I/O; the name gaato/mttp now belongs to the module an app adds
  (formerly gaato/mttp_async). The packages and their API are those of
  gaato/mttp 0.2.0 with the fixes below. In moon.mod, replace
  `"gaato/mttp@0.2.0"` with `"gaato/mttp_core@0.1.0"`; in moon.pkg, replace
  `gaato/mttp` with `gaato/mttp_core` in every import, and
  `gaato/mttp/driver` with `gaato/mttp_core/driver` in
  `allow-experimental-packages`. The root package's default alias becomes
  `@mttp_core`: rename `@mttp.` to `@mttp_core.` in code, or keep the code
  and import the root under an alias (`"gaato/mttp_core" @mttp`).

### Fixed

- HTTP/1 request targets now validate RFC 3986 path/query characters and
  percent escapes before URL construction, refusing malformed origin-form
  and absolute-form targets instead of handing them to the handler.
- `h1client` no longer writes a request to a parked connection the server
  has closed. Servers close idle keep-alive connections after a few seconds
  (Apache after 5), and a POST sent after such a pause failed as sent, so it
  could not be resent although the server never saw it; a response the
  server sent on the idle connection (such as a 408) could be taken as the
  answer to the next request. A connection parked for 100 ms or more is now
  checked before reuse, waiting at most 2 ms, and dropped if the server
  closed it or wrote to it.
- `h1client` sends a request on another connection, whatever its method,
  when a reused connection refuses its first write with nothing sent. The
  check above can miss a close that is already there: core/async counts
  timers in whole milliseconds, so a 1 ms wait could end at once (it
  missed 13 to 20 closes in 200 in a loopback test; the check now waits
  2 ms, which missed none, also under load). Over TLS, a check cut off
  after it took the server's close_notify leaves the session shut down
  without having returned EOF, and OpenSSL then refuses every write: a
  POST failed in phase Write as if sent and was not resent, though the
  server never saw it (seen in the interop suite with nginx and Caddy).
  `rt.Conn` states what makes resending safe: a write that raises `Closed`
  sent none of its bytes. The refusal is reported as `Network`, not
  `Closed`, when it does surface.
- `h1client` honours `Expect: 100-continue` on a request that sets it: the
  body follows the server's 100, or one second without an answer, and a
  final answer that comes first (a 413, say) leaves it unsent. It used to
  send the body at once, so a server refusing it closed the connection while
  the body was still arriving, and the reset that followed could destroy
  the refusal before it was read (seen with Apache over TLS).

## Earlier versions, as gaato/mttp

## [0.2.0] - 2026-11-12

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

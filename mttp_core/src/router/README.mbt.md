# gaato/mttp_core/router

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
    let response = router.dispatch(@mttp_core.Request::get("/hello"))
    assert_eq(response.body, @mttp_core.Bytes(b"hello"))
  })
  router.close()
}
```

## Serving

`Router::handler()` is the `async (@mttp_core.Request) -> @mttp_core.Response` that a
server runs: pass it to `gaato/mttp`'s `@server.serve`, or to
`@fetch.fetch_handler` for a JavaScript `fetch` export. `Router::new` raises
a `DefinitionError` for definitions it refuses; `Router::must` aborts
instead, so a router can be a top-level `let`.

Requests and responses carry `@mttp_core.Attributes`: typed local metadata that is
never sent. When a server shuts down, it lets running responses finish, but
closes a streamed response whose `@mttp_core.close_on_shutdown` attribute is true
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

A WebSocket 101 is the exception: supply `clock`, `timer`, `coordination` and
`background` to the constructor. The background scheduler owns and joins the
server callback. Router connects it to a client-role codec over a byte pair
with 64 KiB per-direction backpressure, and returns the client session under
`@ws.ws_session`. When an extension is negotiated, it instead returns the
take-once byte connection under `@rt.upgraded`, so the client can install
its negotiated Extension without teaching Router any compression algorithm.
Ordinary attributes remain isolated. The caller must close
or abort that session; the empty response body does not own it. Closing the
Router makes the server callback's shutdown probe true.

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
    let form = @mttp_core.Request::post("https://notes.example/notes")
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

## Rate limits

`rate_limit(key~, limit~, window_ms~, clock~, max_keys=10_000)` is opt-in.
It admits at most `limit` requests per key in the exact interval
`(now - window_ms, now]`; rejected requests do not consume quota. A `None`
key bypasses accounting and headers. Accounting happens before the handler,
including handlers that return errors. Each middleware value owns one table
in one process: there is no coordination across processes or replicas.

The least recently used key (including refused requests as accesses) is
forgotten when inserting past `max_keys`. An evicted key starts with a fresh
quota, so choose stable, trusted keys and enough capacity for the active set.
Each key holds at most `limit` timestamps; a decision scans those timestamps.
Nonpositive `limit`, `window_ms` and `max_keys` clamp to one. Clock rollback
retains admissions until they age out; use a clock that advances normally.

429 responses contain a problem+json body and `Retry-After` rounded up to
whole seconds. Every keyed response carries Structured Fields:
`RateLimit-Policy: "default";q=N;w=seconds` and
`RateLimit: "default";r=remaining;t=seconds`. `t` is the time until the oldest
admission expires (the next quota increase), and matches Retry-After on 429.
The format follows [draft-ietf-httpapi-ratelimit-headers-11, 23 May 2026](https://www.ietf.org/archive/id/draft-ietf-httpapi-ratelimit-headers-11.html),
a work in progress, and is serialized with `@sf.serialize_list`.

```mbt check
///|
test "opt-in security policy" {
  let clock = @sim.FakeClock::new()
  let router = @router.Router::new([], options={
    ..@router.ServerOptions::default(),
    middleware: [
      @router.secure_headers(hsts=31_536_000),
      @router.rate_limit(
        key=r => r.attributes.get(@mttp_core.remote_addr),
        limit=100,
        window_ms=60_000,
        clock~,
      ),
    ],
  })
  @driver.run_sync(() => {
    let response = router.dispatch(@mttp_core.Request::get("/"))
    assert_eq(response.headers.get("x-frame-options"), Some("DENY"))
  })
}
```

## Security response headers

`secure_headers(hsts?, content_type_options=true, frame_options=Deny,
referrer_policy="no-referrer", csp?)` fills missing response fields only;
handler fields always win, with case-insensitive lookup. Its defaults add
`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` and
`Referrer-Policy: no-referrer`. `FrameOptions::SameOrigin` selects SAMEORIGIN.
CSP is added only when supplied. HSTS's integer is max-age in seconds
(negative values become zero), and it is added only when the trusted
`connection_scheme` request attribute is exactly `https`. The URL and
forwarded headers do not establish this trust. Put this middleware first
if its headers should also cover responses produced by other middleware.

## Signed cookie sessions

`sessions(sign~, verify~, max_age_ms~, clock~, cookie_name="session",
secure=true, same_site=Lax, max_bytes=4096)` installs the typed `session`
request attribute. Read it with `@endpoint.attribute(@router.session)`.
`Session::get`, `set`, `remove`, `clear` and `changed` operate on string values;
setting an equal value, removing a missing key and clearing an empty session
are no-ops. Values are request-local mutable state, not a server-side store.

The cookie is `base64(payload).base64(signature)` (standard padded base64,
whose alphabet is cookie-safe). The signed UTF-8 JSON payload is
`["expiry-in-unix-ms", {"key":"value"}]`; expiry is inside the authenticated
bytes. Duplicate, tampered, expired, malformed and oversized cookies become
an empty session. Authentication precedes JSON parsing. Values are readable
by clients: signing does not encrypt them.

Only changed sessions send Set-Cookie. A nonempty change renews expiry from
the time the response head returns, with no automatic renewal on reads;
mutations made later by a response stream cannot change that head. A changed
empty session expires the cookie with `Max-Age=0`. Fields always include
HttpOnly, Path=/, Max-Age (milliseconds rounded up to seconds), and SameSite;
Secure is included when enabled. Existing Set-Cookie fields are preserved.
`SameSite` is re-exported from `cookie` (`Lax`, `Strict`, `NoRestriction`, the
last rendered as `None`). Browsers require Secure for SameSite=None.

`max_bytes` bounds the incoming cookie value before decoding, the UTF-8 JSON
value map on `set`, and the entire outgoing Set-Cookie field after signing.
A `set` exceeding its map budget is ignored and does not mark the session
changed. An oversized outgoing field is omitted; keep payloads small enough
for the signature, base64 expansion and cookie attributes. Nonpositive byte
and age limits clamp to one; a cookie name that is not an HTTP token emits
no cookie. Use a separate cookie name or signing domain/key per application.

Supply a secure MAC and a constant-time verifier. For key rotation, sign
with the current key and let verify try the current and retained keys. Clear
prior values on login or another privilege change, then set the new identity
to avoid inheriting attacker-controlled state. This stateless scheme cannot
revoke a copied valid cookie before expiry; removing the browser's cookie
does not invalidate copies. Use short expiry or application-side revocation
when needed, and combine cookie authentication with `same_origin`.

For example, an **application** importing `moonbitlang/x/crypto` can supply
HMAC-SHA256 as below. This is application wiring, not an mttp_core dependency;
`current_key` and `verification_keys` come from the application's secret
store. A fresh hasher per call avoids sharing mutable crypto state.

```mbt nocheck
///|
fn mac(key : Bytes, payload : Bytes) -> Bytes {
  Bytes::from_fixedarray(@crypto.hmac(@crypto.SHA256::new(), key, payload))
}

///|
fn verify_mac(payload : Bytes, signature : Bytes) -> Bool {
  let mut accepted = false
  for key in verification_keys {
    let expected = mac(key, payload)
    let mut difference = signature.length() ^ expected.length()
    for i in 0..<expected.length() {
      difference = difference |
        (expected[i].to_int() ^ signature.get(i).unwrap_or(0).to_int())
    }
    accepted = difference == 0 || accepted
  }
  accepted
}

///|
let middleware = @router.sessions(
  sign=payload => mac(current_key, payload),
  verify=verify_mac,
  max_age_ms=3_600_000,
  clock~,
)
```

The loop above does not exit early on different signature bytes or matching
keys. If your runtime supplies a vetted constant-time comparison, use it;
MoonBit backends do not promise constant-time compilation.

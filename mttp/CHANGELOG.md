# Changelog

All notable changes to `gaato/mttp` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

### Changed

- A TLS connection whose peer closes the connection beneath without
  close_notify raises `IncompleteClose` (gaato/mttp_core) from its reads, on
  MoonBit toolchains after 0.10.20, whose core/async reports such a close;
  it was `Network` there. On 0.10.20, which returns EOF, nothing changes.
  The HTTP/1.1 client and server treat it as EOF except at the end of a
  response body delimited by the close, which now fails as truncated
  (RFC 9112, section 9.8).

## [0.3.0] - 2026-11-12

### Changed

- gaato/mttp_async 0.1 is renamed to gaato/mttp; gaato/mttp 0.2 and earlier
  is now gaato/mttp_core. The suffix made gaato/mttp_async read as an
  asynchronous variant of gaato/mttp, though both are async and the
  difference is the I/O; and most people who add an HTTP module are writing
  an app, so the short name is theirs. This version continues
  gaato/mttp_async 0.1.0, whose history follows; the history of gaato/mttp
  0.1 and 0.2 is in gaato/mttp_core's changelog. A library such as an API
  SDK depends on gaato/mttp_core alone, as it did on gaato/mttp.

  Rename from the top of this table down: the old gaato/mttp first, then
  gaato/mttp_async, or the two end up under one name.

  | Before | After |
  |---|---|
  | `"gaato/mttp@0.2.0"` in moon.mod | `"gaato/mttp_core@0.1.0"`, if a package still imports one of its packages |
  | `gaato/mttp`, `gaato/mttp/<package>` in moon.pkg | `gaato/mttp_core`, `gaato/mttp_core/<package>` |
  | `gaato/mttp/driver` in `allow-experimental-packages` | `gaato/mttp_core/driver` |
  | `@mttp.` in code | `@mttp_core.`, or `@mttp.` for a name gaato/mttp re-exports |
  | `"gaato/mttp_async@0.1.0"` in moon.mod | `"gaato/mttp@0.3.0"` |
  | `gaato/mttp_async`, `gaato/mttp_async/<package>` in moon.pkg | `gaato/mttp`, `gaato/mttp/<package>` |
  | `@mttp_async.` in code | `@mttp.` |
  | `.mooncakes/gaato/mttp_async/hosts/*.mjs` | `.mooncakes/gaato/mttp/hosts/*.mjs` |

### Added

- The root re-exports more of gaato/mttp_core, so that an app that serves
  plain handlers or streams bodies needs no other module: `Handler`,
  `Attributes`, `AttributeKey` and the attribute keys `background`,
  `remote_addr`, `close_on_shutdown` and `replay_safe`; `Url` and
  `UrlError`; `StreamBody`, `BodyStream` and `read_bounded`; and `Backend`
  with its `SendOptions`, the type `client(backend=)` takes. Typed
  endpoints, the router, OpenAPI, multipart, rate limiters and the test
  doubles stay in gaato/mttp_core, which an app that uses them adds too.

### Fixed

- A POST over TLS a few seconds after the server closed the idle
  connection no longer fails in phase Write with `protocol is shutdown`
  (seen in the interop suite with nginx and Caddy). A TLS
  session that refuses a write before passing any of it to the connection
  beneath now raises `Closed`, which gaato/mttp_core's `rt.Conn` reserves
  for a write that sent nothing, and the client sends the request on a new
  connection. A write cut off by closing the connection raises `Network`
  instead of `Closed`, since part of it may have left.

## Earlier versions, as gaato/mttp_async

## [0.1.0] - 2026-11-12

### Added

- First release under this name. gaato/mttp_async continues gaato/http-async
  (its history follows) and is the module an app starts with:
  - `run(async fn)` starts core/async's event loop, so an app imports neither
    core/async nor its experimental opt-in.
  - `client()` returns a Client over the real network with retries on
    (`RetryPolicy::conservative()` under a `RetryBudget`), a 30 s attempt
    and 120 s call deadline, redirects (up to 10) and decompression; with
    `cookies=`, a `CookieJar` (re-exported from `gaato/mttp/cookie`) that
    every redirect hop sends and stores cookies through. `backend=`,
    `clock=` and `timer=` replace the network, the clock and the timers, so
    a test gets the same Client, defaults included, over a stub and a
    virtual clock.
  - The root package re-exports the vocabulary and the client API an app
    needs (`Request`, `Response`, `Client`, `get`, `post`, `as_json` and so
    on), so an app that calls APIs and serves plain handlers needs no other
    module in its `moon.mod`.
  - `backend()`, `clock()` and `timer()` supply the same I/O to a library
    that builds its own Client, such as an API SDK, which keeps its own base
    URL, authentication and retry defaults. `backend()` is the network
    alone, HTTP/1.1 with decompression: the Client built over it follows
    redirects and keeps cookies, as every `Client::new` does.
  - `coordination()` supplies the event loop's signals to the parts of
    `gaato/mttp` that wait without I/O, such as `EventStream::channel`.
- `ListenError` implements `Show`.
- The Deno, Bun and Node host shims (`hosts/adapters.mjs`) return `shutdown()`
  beside `fetch` and `whenIdle`. It ends every in-flight response whose
  `@mttp.Response` sets `close_on_shutdown`, such as an `endpoint.sse_out`
  stream: the body ends cleanly after a whole event and is closed once, so the
  host's own shutdown no longer waits for it, also for a stream that has no
  event yet (gaato/mttp's event streams open with an SSE comment, so their
  Response and its mark exist at once). Stop with `app.shutdown()`, then the
  host's server shutdown, then `await app.whenIdle()`.
- `gaato/mttp_async/files` with `static_files(root, prefix?, cache_control?,
  index?)`, a Handler that serves a directory's files to GET and HEAD: streamed
  in 64 KiB slices, `Content-Type` from the extension, a weak `ETag`,
  `Last-Modified`, `Cache-Control` and 304 on a matching `If-None-Match`.
  Segments starting with `.` (dot segments and hidden files such as `.env`),
  empty segments, backslashes and NUL are refused raw or encoded, and the file's
  real path must lie below the root's, so a symlink pointing outside is a 404.
  No directory listings and no ranges.
- `fetch.env_string(env, key)` reads a string binding of a host environment,
  such as a Workers `vars` entry or secret, without hand-written FFI. It is
  `None` when the binding is absent or not a string, and never raises.

### Changed

- `Trust` moved from the root package to `gaato/mttp_async/trust`; the root
  re-exports it.
- Depends on gaato/mttp, which now holds the vocabulary formerly in
  gaato/http.
- The server's shutdown no longer waits `drain_ms` for a streamed response
  with `close_on_shutdown` set, such as every `endpoint.sse_out` response: the
  stream ends when the shutdown starts, and its clients reconnect. Other
  streamed responses are still drained.
- The stale `fetch/pkg.generated.js.mbti` is gone: `moon info` writes only the
  canonical (native) interface, so nothing kept the js-only file current.
- The fetch adapter marks a streamed response with `close_on_shutdown` by a
  function under `Symbol.for("gaato.mttp.closeOnShutdown")`, which a host shim
  calls with its shutdown signal. A pull of a response body cancelled by a host
  event (client disconnect, shutdown) now ends at once instead of waiting for
  unrelated MoonBit work to run.
- A client disconnecting while a fetch response body streams now ends the
  body quietly: its source is closed once and the stream is closed instead of
  errored with `AbortError`, which Deno logged twice per disconnected SSE
  client. A disconnect before the response head still rejects the response
  Promise.
- `server.serve` binds with `SO_REUSEADDR`, as Go and Node do, so a server
  restarted right after it stopped (by systemd, for example) no longer fails
  to bind while the old connections are in TIME-WAIT. Two running servers
  still cannot share a port.
- `ListenError::Bind` and `Accept` keep the cause in `detail`: a bind failure
  names the address and the system's reason (such as `Address already in
  use`), and an address that does not parse says so. They used to say only
  `could not bind server address` and `listener accept failed`.
- The Workers host shim takes a loader, `workers(() => import('./app.js'))`,
  instead of `fetch_with_env`, and imports the app inside the first request.
  The README's static import did not start on workerd: evaluating a compiled
  MoonBit module draws its hash seed from `crypto.getRandomValues`, which
  Workers refuses in global scope. All requests share one import; a failed
  import rejects each request with an Error naming it. The other shims keep
  the static import, which Fastly needs for its synchronous `waitUntil`.
  `scripts/gates.sh full` and CI now run a Workers app on workerd itself.

## Earlier versions, as gaato/http-async

## [0.6.0] - 2026-11-10

### Added

- HTTP/1 listener with bounded admission, graceful shutdown and tracked
  background work; host-neutral streaming fetch handlers and JavaScript host
  shims, including Lambda's absent-body fix; serve and fetch examples.

### Changed

- The module moves from [gaato/mbt-sdk](https://github.com/gaato/mbt-sdk) to
  [gaato/mttp](https://github.com/gaato/mttp) and is rebuilt; no 0.5 API
  carries over.

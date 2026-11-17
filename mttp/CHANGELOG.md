# Changelog

All notable changes to `gaato/mttp` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

### Added

- Opt-in `codings.CompressRequests` Backend wrapper and `compress_request`:
  replayable buffered gzip/deflate/br/zstd request compression, optional lazy
  stream compression, integrity-header exclusions and one uncompressed 415
  fallback only with an excluding Accept-Encoding and a replayable original.
- `files.static_files(ranges=true)`: strong size/mtime ETags, all HTTP
  preconditions and single byte ranges with 206/416 responses. The default
  retains weak ETags and whole-file responses.

- `client()` takes `observer`, `events` and `random` and passes them to the
  `Client` it builds. The root package re-exports `Attempt`, `ClientEvent`,
  `PhaseEvent` and `on_phase`. On native and wasm the socket backend reports
  connection phase events (`Dialed`, `TlsDone`, `Pooled`, `Written`,
  `FirstByte`); JS fetch cannot see them and reports none.
### Changed

- Run socket I/O and supervised primary work in their task group's existing
  child. Close starts a cancellation child only for an outstanding direction;
  normal I/O and supervision each use one fewer task while retaining close
  wakeup, first-outcome ordering, committed reads and joined cleanup.

## [0.4.0] - 2026-11-17

### Changed

- gaato/deflate 0.3.0, gaato/brotli 0.5.0 and gaato/zstd 0.5.1: decoding
  errors read as those releases word them ("the input ends inside ...",
  "data after the last meta-block", "data after the last frame").
- Upgrade gaato/deflate to 0.3.0 for block-boundary checks and dictionary-aware
  reset, and gaato/zstd to 0.5.1, which reports TrailingData for 1–3 trailing
  bytes after a frame.

### Added

- `backend.AsyncBackend::new(max_connection_age_ms?)` forwards an optional
  socket pool lifetime (default off) without changing ClientConfig; construct
  config with `default()` plus record update. JS ignores the socket option.
- `conn.TcpDialer::new(refuse_internal=false)` can opt into a conservative
  RFC 6890/IANA destination policy. It resolves once, refuses internal and
  special-purpose addresses (including restricted IPv4-mapped IPv6) as
  `Invalid/Dial`, and connects the exact answer while keeping hostname SNI.
  Each redirect dial is checked. With a proxy only its address is checked;
  target restrictions belong at the proxy.
- Opt-in WebSocket permessage-deflate through `compression=Compression::new()`
  on connect and upgrade, with RFC 7692 negotiation, per-direction context
  takeover, fixed window 15 encoding and bounded inflation (Close 1009).
  JS hosts retain their own compression behavior and ignore this option.

### Fixed

- Workers WebSocket operations register their completion callbacks in the
  socket's request context, so another request ending cannot drop them when
  the shared MoonBit scheduler resumes a session there. Client handshakes
  start and register their completion callbacks in the owning request too.
- Document the TCP dialer limitation: with refuse_internal, only the first
  resolved address is tried. core/async exposes no complete DNS candidate
  set (`AddrInfo::next`/`to_addr` are private) or per-candidate validation
  hook for `connect_to_host`; guarded dialing therefore has no fallback
  across addresses and still connects the single checked answer directly.
- permessage-deflate reuses one Decoder's storage across BFINAL members and
  bounds restarts at eight per message (Close 1009). Dictionary-aware reset
  restores the exact last 32 KiB of LZ77 history.
- permessage-deflate supplies only the RFC four-byte tail, separately with
  output checked and `Decoder::at_block_boundary()` required afterwards;
  tail-generated data and unfinished stored headers are Close 1002. The
  RFC 7692 section 7.2.3.4 final-stream example is accepted in both roles
  under every input split.

- JS WebSocket abort requests host `close()` without a status instead of
  normal Close 1000, while retaining local Abnormal 1006. The Bun server
  bridge preserves omitted close arguments too.

- JS WebSocket shutdown also supervises startup: CONNECTING sockets use the
  close deadline rather than the send/open deadline, pending Bun upgrades are
  abandoned, and late sockets are closed without starting the handler.

- JS WebSocket shutdown now closes within `close_timeout_ms`, then cancels
  and joins handlers waiting outside `recv`, so process `whenIdle()` settles.
- Deno WebSocket upgrades retain application headers, including separate
  Set-Cookie values, while keeping the host-generated handshake fields.
- Bun WebSocket clients pass a Headers object through the options overload,
  preserving every repeated list-header value in order.

### Added

- `connection_scheme` (re-exported from gaato/mttp_core): the scheme the
  connection was accepted under, set by the server and Router-as-Backend;
  left unset on the JS fetch hosts, whose request URL may keep a
  client-written scheme.

- RFC 9842 compression dictionaries on the server:
  `dictionary_compress(handler, dictionaries)` codes a response with the
  dictionary a request's Available-Dictionary names when it weighs `dcz`
  or `dcb` at least as much as identity and every other coding, it came
  over a secure context (`secure`, by default `secure_context`: a
  connection accepted under https, as `connection_scheme` records; never
  the request's URL, which a client may write as https over cleartext,
  nor a loopback peer, which a local proxy also is), and section 9.3.3's
  Sec-Fetch and CORS check
  passes (`dictionary_allowed`). It adds `Vary: Accept-Encoding,
  Available-Dictionary`, and the check's Sec-Fetch-Site, Sec-Fetch-Mode
  and Origin when it decided, and compresses as `compress` otherwise.
  `use_as_dictionary` marks a response as a dictionary; `encode_body` takes
  a dictionary.

- RFC 9842 compression dictionaries on the client: `Decompress::new` and
  `AsyncBackend::new` take a `@dictionary.DictionaryStore` (and a
  partition). Requests a stored dictionary matches advertise it and accept
  `dcb` and `dcz`; such responses are decoded with it after their header's
  hash is checked; 200 responses with `Use-As-Dictionary` fill the store
  once read to the end. Socket targets only: on JS the host's fetch
  negotiates.

- `Coding` has `Dcb` and `Dcz`; `ContentDecoder::new` and `decode_head`
  take the offered dictionary, `accept_encoding(dictionary=true)` lists
  them, and `ContentEncoder::new(coding, dictionary=)` writes them with a
  `ServerDictionary`.
- `ws.connector(base_url~, backend?)` adapts the existing native/wasm/JS
  connect path for typed WebSocket endpoints. JS also accepts a backend
  carrying a ready session, including Router. The socket and fetch server
  adapters execute typed endpoints' portable WebSocket handlers.

- The server compresses with zstd too: `compress` and `negotiate_encoding`
  accept `zstd`, and `ContentEncoder::new(Zstd)` encodes at level 3 (a 2 MiB
  window, within RFC 9659's 8 MB) instead of raising. At equal weights gzip,
  deflate and Brotli still come first, so answers to clients that offer
  them do not change.

### Changed

- Socket connections reuse receive storage instead of zeroing 64 KiB on
  every read. Storage starts at up to 4 KiB and doubles only after full
  reads, retaining the 64 KiB ceiling and cancellation-safe committed bytes.

- `ContentEncoder::new` no longer raises: every coding has an encoder.
  Callers that caught its Invalid can drop the handler.
- JS `ws.connect` supplies a bounded host-message Session on Node, Deno, Bun,
  browsers and Workers (fetch upgrade). `ws.upgrade` integrates with Workers'
  WebSocketPair, Deno.upgradeWebSocket and Bun server.upgrade in fetch_handler;
  Node's fetch server returns 501. Bun shims forward the server argument and
  expose websocket callbacks. Host limitations and queue bounds are documented
  in hosts/README.md; real workerd and JS interop checks cover echo and Close.

- `ws.upgrade` validates server handshakes, selects subprotocols and hands a
  bounded Session to a handler. Shutdown sends GoingAway and retains the
  connection's admission slot until completion or the listener drain deadline.

- Decompress reclaims unclaimed upgrade metadata on a head-decoding refusal;
  ws.connect cleanup also guards the unclaimed interval before acquisition.
  Runtime tests count actual h1 slot reuse after handshake/decoder failure
  and release cancellation, and inject cancellation at response/take boundaries.

- `ws.connect` opens ws/wss sessions over a caller backend or the default
  TLS/proxy backend, with secure runtime entropy, subprotocol validation,
  explicit limits, and no redirects. Extensions refuse until their later
  stage. The native client is tested against Autobahn fuzzingserver.

- `RuntimeCoordination.protect(work~)` implements the new mttp_core
  cancellation-protection port with core/async's `protect_from_cancel`, so
  bounded WebSocket control replies can finish before a receiver is cancelled.
  Its behavior is covered by the same coordination contract check as sim.

- `server.serve(auto_date~ : Bool = true)` passes through the HTTP/1
  engine's automatic Date setting. Final responses without a handler's
  Date now carry it, including errors and HEAD/204/304; `auto_date=false`
  disables insertion. JS fetch hosts are unchanged.
- The root re-exports gaato/mttp_core's `abandon_request_body` and
  `protocol` attribute keys. Responses of the HTTP/1.1 backend carry
  `protocol` (`http/1.1` or `http/1.0`), and so do requests that
  `@server.serve` hands to a handler; the JS fetch backend leaves it unset,
  since fetch does not say which protocol it used.

### Changed

- `server.serve` writes Bytes and Empty responses directly, keeping per-write
  deadlines and shutdown admission through the engine's completion signal
  instead of wrapping fixed bodies in a timed stream.

- `@server.serve` ends the connection after a 413 from a Router as before,
  now because the Router sets `abandon_request_body` instead of writing
  `Connection: close` itself.

- A TLS connection whose peer closes the connection beneath without
  close_notify raises `IncompleteClose` (gaato/mttp_core) from its reads, on
  MoonBit toolchains after 0.10.20, whose core/async reports such a close;
  it was `Network` there. On 0.10.20, which returns EOF, nothing changes.
  The HTTP/1.1 client and server treat it as EOF except at the end of a
  response body delimited by the close, which now fails as truncated
  (RFC 9112, section 9.8).
- mttp requires gaato/zstd 0.4.1, gaato/brotli 0.4.3, gaato/deflate 0.1.2
  and gaato/codec_bytes 0.1.2. Decompressing zstd response bodies is 2.6 to
  3.1 times as fast, Brotli 1.5 times on native and 1.6 times on JS, and
  gzip and deflate on JS 1.2 times. The output and the errors are
  unchanged.

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

- Autobahn server/client known cases now require the exact behavior and
  closing verdicts. INFORMATIONAL expectations no longer hide FAILED or
  missing verdicts; adapter/runner regressions run in static and full gates.

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

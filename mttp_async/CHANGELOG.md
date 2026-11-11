# Changelog

All notable changes to `gaato/mttp_async` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

### Added

- First release under this name. gaato/mttp_async continues gaato/http-async
  (its history follows) and is the module an app adds:
  - `run(async fn)` starts core/async's event loop, so an app imports neither
    core/async nor its experimental opt-in.
  - `client()` returns a Client over the real network with retries on
    (`RetryPolicy::conservative()` under a `RetryBudget`), a 30 s attempt
    and 120 s call deadline, redirects (up to 10) and decompression.
  - The root package re-exports the vocabulary and the client API an app
    needs (`Request`, `Response`, `Client`, `get`, `post`, `as_json` and so
    on), so `gaato/mttp_async` is the only module in its `moon.mod`.

### Changed

- `Trust` moved from the root package to `gaato/mttp_async/trust`; the root
  re-exports it.
- Depends on gaato/mttp, which now holds the vocabulary formerly in
  gaato/http.

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

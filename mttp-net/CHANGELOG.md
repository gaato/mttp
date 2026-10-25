# Changelog

## [Unreleased]

## [0.1.0] - 2026-10-26

### Added

- HTTP/1.1 client and server adapters for native and Wasm, including TLS,
  connection pooling, proxy tunnels, bounded bodies and phase deadlines.
- Fetch adapters for JavaScript hosts, with bounded uploads and explicit
  response-body and cancellation ownership.
- Content coding adapters and the quick client facade over `gaato/mttp`.

### Fixed

- Finish responses after a client closes only its sending half. A read EOF
  alone no longer cancels a handler; use `handler_timeout_ms` to bound a
  suspended handler when a graceful full close cannot yet be distinguished.
- Make the upload-failure regression test wait for the head phase before
  triggering a timeout or malformed response, avoiding wall-clock races.

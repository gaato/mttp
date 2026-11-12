# Changelog

All notable changes to `gaato/mttp_moonfetch` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the
version is 0.x, a minor release (0.x → 0.y) may contain breaking changes; a
patch release never does.

## [Unreleased]

### Added

- `backend(http3?, proxy?, tls?)`: gaato/mttp's `Backend` over
  moonbitstack/moonfetch, with HTTP/2 by ALPN, HTTP/3 when asked, and
  responses decompressed as `@mttp_async.backend()` decompresses them.
- `http_version`: the response attribute naming the HTTP version an exchange
  used.

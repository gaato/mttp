# Changelog

All notable changes to `gaato/mttp_digest` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

## [0.3.0] - 2026-11-12

### Changed

- Depends on gaato/mttp_core 0.1.0, the new name of gaato/mttp 0.2.0, the
  module without I/O: `DigestScheme` wraps a `&@mttp_core.Backend` and
  raises `@mttp_core.TransportError`, the same types as before under their
  new module. The app module, gaato/mttp_async until now, is gaato/mttp
  0.3.0, so in an app `client(backend=DigestScheme::new(@mttp.backend(), ..))`
  works as before with `@mttp` in place of `@mttp_async`. A library that
  builds its Client with `Client::new` imports `gaato/mttp_core/client`.

## [0.2.0] - 2026-11-12

### Changed

- `DigestScheme` wraps a `gaato/mttp` Backend (`&@mttp.Backend`) instead of a
  `gaato/http` one, and raises `@mttp.TransportError`: gaato/http is now part
  of gaato/mttp. Replace `gaato/http` with `gaato/mttp` in moon.mod and
  moon.pkg, and `@http.` with `@mttp.` in code.
- A Client follows redirects itself, outside the backend it is given, so
  `Client::new(DigestScheme::new(backend, ..), ..)` checks every hop against
  the credential origin without a `FollowRedirects` around the wrapper; with
  `gaato/mttp_async`, pass it as `client(backend=DigestScheme::new(
  @mttp_async.backend(), ..))`. Drop the `FollowRedirects` from a stack that
  had one, or give its Client `redirect=RedirectConfig::none()`.

## [0.1.0] - 2026-11-10

### Added

- First release: origin-scoped Digest authentication as a
  `gaato/http.Backend` wrapper, with MD5 and SHA-256, bounded challenges and
  nonce state, and nonce counts shared across concurrent challenges.

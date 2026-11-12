# Changelog

All notable changes to `gaato/mttp_digest` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

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

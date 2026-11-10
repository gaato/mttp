# Changelog

All notable changes to `gaato/mttp_digest` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

## [0.1.0] - 2026-11-10

### Added

- First release: origin-scoped Digest authentication as a
  `gaato/http.Backend` wrapper, with MD5 and SHA-256, bounded challenges and
  nonce state, and nonce counts shared across concurrent challenges.

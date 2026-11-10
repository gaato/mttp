# Changelog

All notable changes to `gaato/mttp_digest` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

### Added

- Port origin-scoped Digest authentication to `gaato/http.Backend` and
  `SendOptions`, with MD5, SHA-256, nonce bounds and all-target contract tests.

### Fixed

- Preserve nonce counts across concurrent challenges carrying the same nonce,
  and allocate each challenge response's count from the shared cache. New
  nonces and `stale=true` reset to one; exhausted counts are refused.
- Classify failures after an answered challenge as sent, preventing an
  unsent-only retry from repeating a POST; close uploads on refusal and
  cancellation.

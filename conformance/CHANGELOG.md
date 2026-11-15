# Changelog

## [Unreleased]

### Changed

- Document llhttp's acceptance of a raw pipe in a request query as a
  difference: mttp validates RFC 3986 wire targets before URL construction.

### Added

- Port the private HTTP URL, form, cookie and SSE corpora to gaato/http and
  gaato/mttp, with equal test counts on all four targets. IPv6 addresses
  containing IPv4 tails now participate in the URL corpus.
- Check the HTTP/1 codec against llhttp's request and response tests and
  web-platform-tests' HTTP/1 response parsing tables, with the cases where
  mttp is stricter listed with their reasons. scripts/gen_vectors.mbtx now
  exists and regenerates every GENERATED file here.

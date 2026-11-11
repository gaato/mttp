# Changelog

All notable changes to `gaato/mttp` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

### Changed

- OpenAPI documents describe each server-sent event in OpenAPI 3.2's item
  shape, under the media type's `x-oai-itemSchema` extension, instead of
  `x-mttp-sse-data-schema` inside the schema. The documents stay OpenAPI 3.1.
  `VariantDoc` gains `item_schema` (experimental `endpoint` package).
- gaato/http is now part of gaato/mttp. Its vocabulary (`Request`, `Response`, `Body`, `Backend` and the rest) is the root package, `@mttp`, and `h1`, `rt`, `sim`, `driver`, `h1client` and `h1server` are `gaato/mttp/...`. Replace `gaato/http` with `gaato/mttp` in moon.mod and moon.pkg, and `@http.` with `@mttp.` in code. gaato/mttp no longer depends on any module.

## [0.1.0] - 2026-11-10

### Added

- First release: a client on `gaato/http.Backend` with retries, rate limits,
  deadlines, redirects and cookies; typed response readers, server-sent
  events and multipart; schemas, endpoints, a router and OpenAPI; test stubs.

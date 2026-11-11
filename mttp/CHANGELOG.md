# Changelog

All notable changes to `gaato/mttp` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

### Removed

- The endpoint layer moved to its own module,
  [`gaato/mttp_endpoint`](https://mooncakes.io/docs/gaato/mttp_endpoint):
  `endpoint`, `endpoint/testkit`, `router`, `apispec` and `openapi`. They were
  experimental, so this patch release removes them; import them from
  `gaato/mttp_endpoint/...` instead. gaato/discord 0.15.0 imports them from
  here, so use gaato/discord 0.15.1 or later with this version.

## [0.1.0] - 2026-11-10

### Added

- First release: a client on `gaato/http.Backend` with retries, rate limits,
  deadlines, redirects and cookies; typed response readers, server-sent
  events and multipart; schemas, endpoints, a router and OpenAPI; test stubs.

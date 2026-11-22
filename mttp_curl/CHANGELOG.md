# Changelog

All notable changes to `gaato/mttp_curl` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does.

## [Unreleased]

### Added

- `backend(http3?, trust?, proxy?, max_connection_age_ms?)`: the network
  over the system's libcurl, for `@mttp.client(backend=...)`, with
  responses decoded as `@mttp.backend()` decodes them. HTTP/1.1 and HTTP/2
  by ALPN, every request to an `https` origin on one HTTP/2 connection, and
  HTTP/3 with `http3=true` over a libcurl that has it. Native, on Linux and
  macOS; libcurl 7.85 or later.
- `CurlBackend`: the same backend without decoding, implementing
  gaato/mttp_core's `Backend`, with `CurlBackend::supports_http3()` and
  `CurlBackend::libcurl_version()`.
- Proxies from the environment by default, or a `ProxyConfig`; phase
  events for `on_phase` and the Client's `events`; the carrying protocol
  under `@mttp_core.protocol`.

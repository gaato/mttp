# Changelog

All notable changes to `gaato/mttp` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.1.0] - 2026-10-26

### Added

- Clock traits, deterministic clock/timer/gate fakes, JSON helpers,
  immutable HTTP model values, bounded SSE parsing, multipart encoding,
  retry decisions and scripted body feeds.
- Four-target test-count manifests and documentation, layout, resource-bound
  and coverage checks; pinned CI and latest/nightly canaries.

- The `gaato/mttp` module: the root package and its overview.
- `gaato/mttp/testing/driver` (experimental): a deterministic
  single-threaded `Driver` with virtual time (spawn, park and one-shot
  wakers, cancellation that runs `defer` and `errdefer`, timers) and
  `run_sync`. It raises `DriverError` instead of aborting. It is built on
  compiler intrinsics and may break with toolchain changes.

### Fixed

- Preserve response streams transferred into lazy middleware wrappers.
- Accept explicit port 80 in CONNECT request parsing and serialization.
- Reject dot-only endpoint path captures before URL normalization can change
  their route. `Endpoint::request` now raises `InvalidRequest` for these inputs.
- Include `Vary: Origin` on denied and missing-origin CORS responses when
  using an origin allowlist or credentialed origin reflection.
- Bound Driver timer callbacks and reserve a fresh cancellation cleanup
  budget, including after the main execution budget is exhausted.
- Preserve URL fragments when appending query parameters.

# Changelog

All notable changes to `gaato/mttp_endpoint` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the
version is 0.x, a minor release (0.x → 0.y) may contain breaking changes; a
patch release never does.

## [Unreleased]

### Added

- First release: the endpoint layer of `gaato/mttp` 0.1.0 as its own module,
  under `gaato/mttp_endpoint/{endpoint,endpoint/testkit,router,apispec,openapi}`.
  The packages are no longer experimental; this module's 0.x versions carry
  their breaking changes. OpenAPI documents describe each server-sent event in
  OpenAPI 3.2's item shape under the media type's `x-oai-itemSchema` extension.

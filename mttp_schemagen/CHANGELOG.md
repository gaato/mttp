# Changelog

## [Unreleased]

## [0.1.0] - 2026-11-18

### Added

- Generate ordinary mttp_core object, enum and recursive JSON codecs from
  `#mttp.schema` types, without adding parser dependencies to consumers.
- `schema_default` documents a default without applying it on decode;
  the prototype spelling `default` now reports a migration error.
- Required nullable fields, configurable enum discriminators and wire tags,
  and an optional `unknown` case preserving unknown response JSON.
- Versioned headers, generated-file ownership checks, byte comparison mode,
  positioned hard errors and compilation of newly generated collision fixtures.

The output requires `gaato/mttp_core` 0.3.0 or later, which adds the
description and required-nullable APIs and `tagged(unknown?)`.

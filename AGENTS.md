# Agent notes

## Documentation

- A module README is also read raw by coding agents in a user's
  `.mooncakes/`. They copy its examples, take every sentence literally, fill
  what it leaves out with guesses, and read the published text until the next
  release, while the modules it might mention change and get renamed.

## API changes

- When a published function's labelled parameter is renamed or removed, an
  optional one becomes required, or a positional one becomes labelled, keep
  existing calls compiling for one minor release with `#label_migration`
  (`alias=old`, `fill=false`, `fill=true` or `allow_positional=true`) and a
  `msg` naming the new form, and remove the attribute in the next minor
  release. Callers then get a warning instead of a build failure; the
  CHANGELOG still lists the change with its migration note. A renamed or
  removed function keeps a `#deprecated` alias for the same period.
